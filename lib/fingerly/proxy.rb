# frozen_string_literal: true

require "net/http"

module Fingerly
  # What +client_ip+ is given: one incoming request, already parsed out of the
  # Rack environment.
  #
  # Rack spells headers +HTTP_CF_CONNECTING_IP+; this spells them the way they
  # arrived, matched without regard to case.
  class ProxyRequest
    include Redacted

    # @return [String] the HTTP method. Named for Rack's own +request_method+
    #   rather than +method+, which every Ruby object already answers to.
    attr_reader :request_method
    # @return [String] the request path as the application sees it
    attr_reader :path
    # @return [String, nil] the socket peer's address, when the server reports
    #   one. This is your load balancer, not the visitor, whenever one is in
    #   front of you.
    attr_reader :peer_host

    # @api private
    def initialize(env, path)
      @request_method = env["REQUEST_METHOD"].to_s
      @path = path
      @peer_host = env["REMOTE_ADDR"]
      @headers = ProxyRequest.headers_from(env)
      freeze
    end

    # One header, matched without regard to case.
    #
    # @param name [String] the header name, as HTTP spells it
    # @return [String, nil] the value, or nil when the request carried none
    def header(name)
      @headers[name.to_s.downcase]
    end

    # @return [Hash{String=>String}] every header, lowercased, with repeats
    #   joined by ", " as HTTP defines
    attr_reader :headers

    # @api private
    def self.headers_from(env)
      headers = {}
      env.each do |key, value|
        next unless value.is_a?(String)

        name =
          if key.start_with?("HTTP_") then key[5..].downcase.tr("_", "-")
          elsif %w[CONTENT_TYPE CONTENT_LENGTH].include?(key) then key.downcase.tr("_", "-")
          end
        headers[name] = value if name
      end
      headers.freeze
    end

    private

    # The visitor's cookies and authorization header are in +headers+; a
    # client_ip that logs the request must not print them.
    def redacted_fields
      [["method", @request_method], ["path", @path], ["peer_host", @peer_host.inspect]]
    end
  end

  # Same-origin proxy for the browser SDK, as a Rack application or middleware.
  #
  # Content blockers refuse browser requests to third-party APIs, and a refused
  # identification is a visitor never identified. Mounting this on a path of
  # your own site makes those requests first-party. The proxy key is what lets
  # that hop declare the visitor's real address, origin and user agent; a
  # public key alone never can, so nobody can spoof them.
  #
  # Rack is the one interface every Ruby server and framework shares, so there
  # is one adapter and no per-framework variants:
  #
  #   # config/application.rb
  #   config.middleware.use Fingerly::Proxy,
  #     proxy_key: ENV.fetch("FINGERLY_PROXY_KEY"),
  #     path: "/k7x2qm4a",
  #     client_ip: ->(request) { request.header("CF-Connecting-IP") }
  #
  # The browser SDK posts both of its calls to that one path, and each is
  # forwarded to Fingerly's one ingest URL, never anywhere else and never to
  # event reads. Customer cookies and authorization headers are never passed
  # on, and nothing that names Fingerly is relayed back.
  class Proxy
    include Redacted

    DEFAULT_MAX_BODY_BYTES = 1 << 20
    DEFAULT_TIMEOUT = 5
    USER_AGENT = "fingerly-ruby/#{VERSION}".freeze
    # What this proxy reports itself as upstream; shown per proxy in the
    # dashboard.
    PROXY_VERSION = "ruby/#{VERSION}".freeze

    # Statuses that must not carry a body.
    BODILESS = [204, 205, 304].freeze

    # The response headers relayed to the browser, and nothing else. A content
    # blocker can match a response header by name, so an allowlist is what
    # keeps anything naming Fingerly off the page, whatever the API adds in
    # future. It also leaves out every header that describes the upstream
    # connection rather than the bytes handed back, and +set-cookie+, the one
    # header whose values cannot be joined into the string Rack 2 and Rack 3
    # both accept.
    RELAYED_HEADERS = %w[
      content-type x-request-id ratelimit-limit ratelimit-remaining retry-after
    ].freeze

    # @return [Integer] the request body limit in bytes
    attr_reader :max_body_bytes
    # @return [String, nil] the one path answered, without a trailing slash, or
    #   nil to answer whatever the framework routes here
    attr_reader :path
    # @return [String] the API route version forwarded upstream
    attr_reader :api_version

    # @param app [#call, nil] the rest of the Rack stack. Rack passes this
    #   when the proxy is used as middleware, which then needs +path+ to know
    #   which request is its own; without one, a path the proxy does not serve
    #   gets 404.
    # @param client_ip [#call] resolves the visitor's address from a
    #   {ProxyRequest}. Read it from a header your own infrastructure sets,
    #   such as your load balancer's or CDN's. Never use the left-most
    #   +X-Forwarded-For+ value: the visitor writes it.
    # @param proxy_key [String, nil] a write-only credential, +fly_px_…+, held
    #   only on your server
    # @param secret_key [String, nil] the deprecated alternative to
    #   +proxy_key+. Secret read keys will be refused in the next major
    #   version; do not pass both.
    # @param path [String, nil] the path the dashboard issued for this proxy,
    #   such as +/k7x2qm4a+, matched exactly. Omit it only where the framework
    #   already routes that path here, as a Rails +mount+ or a +Rack::URLMap+
    #   entry does; the proxy then answers whatever it is handed.
    # @param api_version [String] the version of the upstream ingest URL
    # @param upstream [String, nil] overrides the API origin implied by the key
    # @param max_body_bytes [Integer] larger request bodies are refused with 413
    # @param timeout [Numeric] how long to wait for Fingerly, in seconds
    # @param configure_http [Proc, nil] receives the +Net::HTTP+ before it connects
    # @raise [ConfigurationError] if a credential, path, limit or callback is
    #   invalid, or if the proxy is middleware without a path. A proxy is wired
    #   up once at start-up, where an error is natural to handle.
    def initialize(app = nil, client_ip:, proxy_key: nil, secret_key: nil,
                   path: nil, api_version: "v1", upstream: nil,
                   max_body_bytes: DEFAULT_MAX_BODY_BYTES, timeout: DEFAULT_TIMEOUT,
                   configure_http: nil)
      raise ConfigurationError, "A Fingerly proxy key is required" if !proxy_key && !secret_key
      if proxy_key && secret_key
        raise ConfigurationError, "Pass proxy_key or deprecated secret_key, not both"
      end
      raise ConfigurationError, "client_ip is required" unless client_ip.respond_to?(:call)
      # Middleware sees every request in the stack. Without a path it would
      # take all of them from the application behind it.
      raise ConfigurationError, "path is required when the proxy is middleware" if app && !path

      @app = app
      @client_ip = client_ip
      @uses_proxy_key = !proxy_key.nil?
      @key = proxy_key || secret_key
      @scope = Config.parse_key(@key, @uses_proxy_key ? Config::PROXY : Config::SECRET)
      @path = path.nil? ? nil : Config.normalize_path(path)
      @api_version = Config.normalize_api_version(api_version)
      @ingest = "/api/#{@api_version}/ingest".freeze
      @max_body_bytes = Config.positive_int(max_body_bytes, "max_body_bytes")
      @transport = Transport.new(
        origin: Config.normalize_endpoint(upstream || Config::DEFAULT_ENDPOINT),
        timeout: Config.positive_seconds(timeout, "timeout"),
        configure_http: configure_http
      )
      freeze
    end

    # Whether a path is one this proxy serves.
    #
    # Asked before the body is read. A middleware that called {#call}'s
    # forwarding path to find out would have consumed +rack.input+ doing it,
    # and under Rack 3 that stream is not required to rewind, so the
    # application it passed the request along to would receive nothing.
    #
    # Trailing slashes are ignored on both sides. Without a configured +path+
    # every request is the proxy's, because the framework routed it here.
    #
    # @param path [String] the request path
    # @return [Boolean]
    def handles?(path)
      @path.nil? || path.to_s.sub(%r{/+\z}, "") == @path
    end

    # Serves one Rack request.
    #
    # @param env [Hash] the Rack environment
    # @return [Array(Integer, Hash, Array<String>)] a Rack response
    def call(env)
      # PATH_INFO alone, never SCRIPT_NAME + PATH_INFO. Under a sub-URI
      # deployment SCRIPT_NAME is a detail the configured path knows nothing
      # about, so the application-relative path is the one that means the
      # same thing wherever the application is deployed.
      path = env["PATH_INFO"].to_s
      return pass(env) unless handles?(path)

      request = ProxyRequest.new(env, path)
      return refuse(405, "Method Not Allowed", "allow" => "POST") unless
        request.request_method.casecmp("POST").zero?

      api_key = upstream_key_for(request.header("x-api-key"))
      return refuse(401, "Unauthorized") if api_key.nil?

      # Refuse on the declared size first; the read below enforces the real one.
      declared = request.header("content-length").to_i
      return refuse(413, "Payload Too Large") if declared > @max_body_bytes

      body = read_bounded(env["rack.input"])
      return refuse(413, "Payload Too Large") if body.nil?

      forward(request, api_key, body)
    end

    private

    def redacted_fields
      [["path", @path.inspect], ["api_version", @api_version],
       [@uses_proxy_key ? "proxy_key" : "secret_key", Redacted::MARK]]
    end

    def pass(env)
      return @app.call(env) if @app

      refuse(404, "Not Found")
    end

    def forward(request, api_key, body)
      headers = upstream_headers(request, api_key)
      return refuse(500, "Internal Server Error") if headers.nil?

      # Both of the browser SDK's calls go to the one ingest URL, which tells
      # them apart by their bodies.
      result = @transport.call(Net::HTTP::Post, @ingest, headers, body)
      relay(result)
    rescue TimeoutError, ConnectionError
      refuse(502, "Bad Gateway")
    end

    # Decides which key to present upstream.
    #
    # With a proxy key the browser must supply a public key for the same
    # environment, which the proxy forwards alongside its own. The deprecated
    # secret-key mode authenticates on its own.
    #
    # @return [String, nil] the key to forward, or nil when unauthorised
    def upstream_key_for(presented)
      return @key unless @uses_proxy_key

      browser = Config.scope_for(presented, Config::PUBLIC)
      return nil if browser.nil?

      browser == @scope ? presented : nil
    end

    # Builds the headers for the forwarded request.
    #
    # Nothing is copied wholesale: only the body's content type, the visitor
    # metadata Fingerly needs, and an idempotency key when the SDK sent one.
    # The visitor writes the origin, user agent and content type, so each is
    # checked before it is repeated into a header of ours.
    #
    # @return [Hash, nil] nil when client_ip returned something unusable
    def upstream_headers(request, api_key)
      address = @client_ip.call(request)
      # A client_ip that could inject a header is a programming error on the
      # customer's side, not something to forward.
      return nil unless Config.header_safe?(address)

      headers = {
        "content-type" => safe(request.header("content-type")) || "application/json",
        "x-api-key" => api_key,
        "x-fingerly-client-ip" => address,
        "x-fingerly-origin" => safe(request.header("origin")).to_s,
        "x-fingerly-user-agent" => safe(request.header("user-agent")).to_s,
        "x-fingerly-proxy-version" => PROXY_VERSION,
        "user-agent" => USER_AGENT
      }
      headers["x-fingerly-proxy-key"] = @key if @uses_proxy_key
      idempotency = safe(request.header("idempotency-key"))
      headers["idempotency-key"] = idempotency if idempotency && !idempotency.empty?
      headers
    end

    # Drops a visitor-supplied value that could not go in a header.
    def safe(value)
      Config.header_safe?(value) ? value : nil
    end

    # Returns the upstream response, uncacheable and with only the allowlisted
    # headers.
    #
    # Header names are lowercase and repeats joined with ", ", which is the
    # one shape Rack 2 and Rack 3 both accept: Rack 3 refuses an uppercase name
    # outright, and Rack 2 refuses the array Rack 3 would rather have.
    def relay(result)
      headers = { "cache-control" => "no-store" }
      result.headers.each do |name, values|
        key = name.downcase
        headers[key] = Array(values).join(", ") if RELAYED_HEADERS.include?(key)
      end

      body = BODILESS.include?(result.status) ? "" : result.body
      [result.status, headers, [body]]
    end

    # Reads a body without buffering more than the limit.
    #
    # @return [String, nil] the bytes, or nil as soon as the limit is passed
    def read_bounded(input)
      body = "".b
      return body if input.nil?

      while (chunk = input.read(8192))
        body << chunk
        return nil if body.bytesize > @max_body_bytes
      end
      body
    end

    # A plain-text refusal that never reached Fingerly.
    def refuse(status, message, extra = {})
      headers = { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store" }
      [status, headers.merge(extra), [message]]
    end
  end
end
