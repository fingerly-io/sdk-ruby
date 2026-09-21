# frozen_string_literal: true

require "net/http"

module Fingerly
  # What +client_ip+ is given: one incoming request, already parsed out of the
  # Rack environment.
  #
  # Rack spells headers +HTTP_CF_CONNECTING_IP+; this spells them the way they
  # arrived, matched without regard to case.
  class ProxyRequest
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
  end

  # Same-origin proxy for the browser SDK's identify and supplement calls, as
  # Rack middleware.
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
  #     prefix: "/metrics",
  #     client_ip: ->(request) { request.header("CF-Connecting-IP") }
  #
  # Only identify and supplement are forwarded, never event reads: reading
  # events needs a secret key and must stay unreachable from a browser.
  # Customer cookies and authorization headers are never passed on.
  class Proxy
    DEFAULT_PREFIX = "/api/fingerly"
    DEFAULT_MAX_BODY_BYTES = 1 << 20
    DEFAULT_TIMEOUT = 5
    USER_AGENT = "fingerly-ruby/#{VERSION}".freeze

    # Statuses that must not carry a body.
    BODILESS = [204, 205, 304].freeze

    # Upstream headers that describe that connection rather than our response.
    # Net::HTTP has already decoded and reframed the body, so replaying them
    # would misdescribe the bytes handed back. +set-cookie+ is dropped as well:
    # the API sets none, and it is the one header whose values cannot be joined
    # into the single string Rack 2 and Rack 3 both accept.
    CONNECTION_HEADERS = %w[
      connection content-encoding content-length keep-alive proxy-authenticate
      proxy-authorization te trailer transfer-encoding upgrade set-cookie
    ].freeze

    # @return [Integer] the request body limit in bytes
    attr_reader :max_body_bytes
    # @return [String] the path the proxy answers under, without a trailing slash
    attr_reader :prefix
    # @return [String] the API route version accepted locally and forwarded upstream
    attr_reader :api_version

    # @param app [#call, nil] the rest of the Rack stack. Rack passes this
    #   when the proxy is used as middleware; without one, a path the proxy
    #   does not serve gets 404.
    # @param client_ip [#call] resolves the visitor's address from a
    #   {ProxyRequest}. Read it from a header your own infrastructure sets,
    #   such as your load balancer's or CDN's. Never use the left-most
    #   +X-Forwarded-For+ value: the visitor writes it.
    # @param proxy_key [String, nil] a write-only credential, +fly_px_…+, held
    #   only on your server
    # @param secret_key [String, nil] the deprecated alternative to
    #   +proxy_key+. Secret read keys will be refused in the next major
    #   version; do not pass both.
    # @param prefix [String] the path the proxy is mounted under
    # @param api_version [String] the version accepted locally and forwarded
    # @param upstream [String, nil] overrides the API origin implied by the key
    # @param max_body_bytes [Integer] larger request bodies are refused with 413
    # @param timeout [Numeric] how long to wait for Fingerly, in seconds
    # @param configure_http [Proc, nil] receives the +Net::HTTP+ before it connects
    # @raise [ConfigurationError] if a credential, route, limit or callback is
    #   invalid. A proxy is wired up once at start-up, where an error is
    #   natural to handle.
    def initialize(app = nil, client_ip:, proxy_key: nil, secret_key: nil,
                   prefix: DEFAULT_PREFIX, api_version: "v1", upstream: nil,
                   max_body_bytes: DEFAULT_MAX_BODY_BYTES, timeout: DEFAULT_TIMEOUT,
                   configure_http: nil)
      raise ConfigurationError, "A Fingerly proxy key is required" if !proxy_key && !secret_key
      if proxy_key && secret_key
        raise ConfigurationError, "Pass proxy_key or deprecated secret_key, not both"
      end
      raise ConfigurationError, "client_ip is required" unless client_ip.respond_to?(:call)

      @app = app
      @client_ip = client_ip
      @uses_proxy_key = !proxy_key.nil?
      @key = proxy_key || secret_key
      @scope = Config.parse_key(@key, @uses_proxy_key ? Config::PROXY : Config::SECRET)
      @prefix = Config.normalize_prefix(prefix)
      @api_version = Config.normalize_api_version(api_version)
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
    # @param path [String] the request path
    # @return [Boolean]
    def handles?(path)
      !route_for(path.to_s).nil?
    end

    # Serves one Rack request.
    #
    # @param env [Hash] the Rack environment
    # @return [Array(Integer, Hash, Array<String>)] a Rack response
    def call(env)
      # PATH_INFO alone, never SCRIPT_NAME + PATH_INFO. Rack puts a mount into
      # SCRIPT_NAME, so under `map "/metrics"` the prefix is already stripped,
      # while under a sub-URI deployment SCRIPT_NAME is a detail the configured
      # prefix knows nothing about. The application-relative path is the only
      # one that means the same thing in both.
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

    def pass(env)
      return @app.call(env) if @app

      refuse(404, "Not Found")
    end

    def forward(request, api_key, body)
      headers = upstream_headers(request, api_key)
      return refuse(500, "Internal Server Error") if headers.nil?

      result = @transport.call(Net::HTTP::Post, route_for(request.path), headers, body)
      relay(result)
    rescue TimeoutError, ConnectionError
      refuse(502, "Bad Gateway")
    end

    # Maps a local request path to its upstream path.
    #
    # The prefix is tolerated as either present or already stripped, so the
    # middleware works whether Rack reported the whole path or only what
    # followed the mount.
    #
    # @return [String, nil] the upstream path, or nil when not proxyable
    def route_for(path)
      versioned = "/api/#{@api_version}"
      resource =
        if path.start_with?(@prefix + versioned) then path.delete_prefix(@prefix + versioned)
        elsif path.start_with?(versioned) then path.delete_prefix(versioned)
        end
      return nil if resource.nil?
      return nil unless resource == "/identify" || supplement?(resource)

      versioned + resource
    end

    # True for /events/{request_id}/supplement with exactly one id segment.
    def supplement?(resource)
      return false unless resource.start_with?("/events/") && resource.end_with?("/supplement")

      request_id = resource.delete_prefix("/events/").delete_suffix("/supplement")
      !request_id.empty? && !request_id.include?("/")
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

    # Returns the upstream response, uncacheable and without its framing.
    #
    # Header names are lowercased and repeats joined with ", ", which is the
    # one shape Rack 2 and Rack 3 both accept: Rack 3 refuses an uppercase name
    # outright, and Rack 2 refuses the array Rack 3 would rather have.
    def relay(result)
      headers = {}
      result.headers.each do |name, values|
        key = name.downcase
        next if CONNECTION_HEADERS.include?(key) || key == "cache-control"

        headers[key] = Array(values).join(", ")
      end
      headers["cache-control"] = "no-store"

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
