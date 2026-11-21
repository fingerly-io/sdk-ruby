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
    # @return [String, nil] the TCP peer's address (+REMOTE_ADDR+), when the
    #   server reports one. This is your load balancer or CDN, not the
    #   visitor, whenever one is in front of you.
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
        headers[name] = headers.key?(name) ? "#{headers[name]}, #{value}" : value if name
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

    # The answer when client_ip returns anything but one IP address.
    NO_CLIENT_IP = "The client IP callback returned no valid address"

    # JSON refusal when both Origin and a validated native SDK platform are absent.
    MISSING_ORIGIN_JSON =
      "{\"error\":{\"code\":\"missing_origin\",\"message\":\"Missing origin\",\"status\":400}}"

    # Exact lowercase native/bridge identifiers allowed in x-fingerly-sdk-platform.
    ALLOWED_PLATFORMS = Regexp.new(
      "\\A(ios|android|react-native|react-native-ios|react-native-android|" \
      "flutter|flutter-ios|flutter-android|lynx-ios|lynx-android|" \
      "capacitor|kotlin-multiplatform)\\z"
    ).freeze

    # Allowlisted client headers forwarded verbatim when present and header-safe.
    FORWARDED_CLIENT_HEADERS = %w[
      idempotency-key sec-fetch-site sec-fetch-mode sec-fetch-dest
      sec-ch-ua sec-ch-ua-mobile sec-ch-ua-platform
    ].freeze

    # Web Bot Auth headers an AI agent's browser signs the request with,
    # forwarded when present, header-safe and at most
    # +MAX_SIGNATURE_HEADER_BYTES+. The API ignores a longer one, so it is
    # dropped here rather than refused.
    SIGNATURE_HEADERS = %w[signature signature-input signature-agent].freeze

    # The longest Web Bot Auth header value forwarded, in bytes.
    MAX_SIGNATURE_HEADER_BYTES = 4096

    # Upstream statuses that can be relayed; 3xx inside this range is not.
    RELAYABLE_STATUS = (200..599)

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
    # @return [String] the one path answered, without a trailing slash
    attr_reader :path
    # @return [String] the API route version forwarded upstream
    attr_reader :api_version

    # @param app [#call, nil] the rest of the Rack stack. Rack passes this
    #   when the proxy is used as middleware; without one, a path the proxy
    #   does not serve gets 404.
    # @param client_ip [#call] resolves the visitor's address from a
    #   {ProxyRequest}. Read it from a header your own infrastructure sets,
    #   such as your load balancer's or CDN's. Never use the left-most
    #   +X-Forwarded-For+ value: the visitor writes it.
    # @param proxy_key [String] a write-only credential, +fly_px_…+, held only
    #   on your server. Required. Every forwarded request carries it as
    #   +X-Fingerly-Proxy-Key+ alongside the browser's public key, which must
    #   be scoped to the same environment.
    # @param path [String] the path the dashboard issued for this proxy, such
    #   as +/k7x2qm4a+, matched exactly against +PATH_INFO+. Required.
    # @param api_version [String] the version of the upstream ingest URL
    # @param upstream [String, nil] overrides the API origin implied by the key:
    #   a bare origin, scheme, host and optional port, and +https+ only
    # @param allow_insecure_loopback [Boolean] lets +upstream+ be a plain
    #   +http+ origin on 127.0.0.1, localhost or [::1], for local development
    #   and tests. Off by default.
    # @param max_body_bytes [Integer] larger request bodies are refused with 413
    # @param timeout [Numeric] how long to wait for Fingerly, in seconds
    # @param configure_http [Proc, nil] receives the +Net::HTTP+ before it connects
    # @param logger [#warn, nil] receives one line per failed upstream call.
    #   Without one, +rack.logger+ is used when the server provides it, and
    #   standard error otherwise.
    # @raise [ConfigurationError] if a credential, path, limit or callback is
    #   missing or invalid. A proxy is wired up once at start-up, where an error is
    #   natural to handle.
    def initialize(app = nil, client_ip:, proxy_key:,
                   path: nil, allowed_origins: nil, api_version: "v1", upstream: nil,
                   max_body_bytes: DEFAULT_MAX_BODY_BYTES, timeout: DEFAULT_TIMEOUT,
                   configure_http: nil, logger: nil, allow_insecure_loopback: false)
      scope = Config.scope_for(proxy_key, Config::PROXY)
      unless scope
        raise ConfigurationError,
              "proxy_key must be a Fingerly proxy key, fly_px_<environment>_..., " \
              "for the production, staging or development environment"
      end
      raise ConfigurationError, "client_ip is required" unless client_ip.respond_to?(:call)
      raise ConfigurationError, "path is required" if path.nil?

      if logger && !logger.respond_to?(:warn)
        raise ConfigurationError, "logger must respond to warn"
      end

      @app = app
      @logger = logger
      # Set once the client_ip misconfiguration has been logged, so a broken
      # callback costs one log line per process rather than one per visitor.
      @misconfigured = []
      @misconfigured_lock = Mutex.new
      @client_ip = client_ip
      @key = proxy_key
      @scope = scope
      @path = Config.normalize_path(path)
      @allowed_origins = normalize_origins(allowed_origins)
      @api_version = Config.normalize_api_version(api_version)
      @ingest = "/api/#{@api_version}/ingest".freeze
      @max_body_bytes = Config.positive_int(max_body_bytes, "max_body_bytes")
      @transport = Transport.new(
        origin: Config.normalize_origin(upstream || Config::DEFAULT_ENDPOINT, "upstream",
                                        allow_insecure_loopback: allow_insecure_loopback == true),
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
    # The match is exact and case-sensitive: no trailing or doubled slash, no
    # dot segment, no encoded slash, nothing under the path.
    #
    # @param path [String] the request path
    # @return [Boolean]
    def handles?(path)
      path.to_s == @path
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

      serve(env, ProxyRequest.new(env, path))
    end

    private

    # Handles a request that is this proxy's own.
    #
    # Separate from {#call} so the rescue below can never reach the application
    # behind the middleware: an +Errno::ENOENT+ or an +IOError+ raised by the
    # host application is that application's error, not a visitor hanging up.
    def serve(env, request)
      sdk_platform = validated_platform(request.header("x-fingerly-sdk-platform"))
      origin = non_blank(safe(request.header("origin")))
      cors = cors_headers(origin)

      # Methods are case-sensitive in HTTP: +post+ is not +POST+.
      if !@allowed_origins.empty? && request.request_method == "OPTIONS"
        return preflight(origin, cors)
      end

      unless request.request_method == "POST"
        allow = @allowed_origins.empty? ? "POST" : "POST, OPTIONS"
        return refuse(405, "Method Not Allowed", cors.merge("allow" => allow))
      end

      api_key = upstream_key_for(request.header("x-api-key"))
      return refuse(401, "Unauthorized", cors) if api_key.nil?
      return json_refuse(400, MISSING_ORIGIN_JSON, cors) if origin.nil? && sdk_platform.nil?

      # Refuse on the declared size first; the read below enforces the real one.
      declared = request.header("content-length").to_i
      return refuse(413, "Payload Too Large", cors) if declared > @max_body_bytes

      body = read_bounded(env["rack.input"])
      return refuse(413, "Payload Too Large", cors) if body.nil?

      forward(env, request, api_key, body, origin: origin, sdk_platform: sdk_platform, cors: cors)
    rescue IOError, SystemCallError
      # The visitor went away while the body was arriving. Nobody is left to
      # read an answer, and there is nothing worth logging.
      refuse(400, "Bad request", cors || {})
    end

    def redacted_fields
      [["path", @path.inspect], ["api_version", @api_version],
       ["proxy_key", Redacted::MARK]]
    end

    def pass(env)
      return @app.call(env) if @app

      refuse(404, "Not Found")
    end

    def forward(env, request, api_key, body, origin:, sdk_platform:, cors:)
      address = client_address(env, request)
      return refuse(500, NO_CLIENT_IP, cors) if address.nil?

      headers = upstream_headers(request, api_key, address, origin, sdk_platform)

      # Client SDK envelopes go to the one ingest URL verbatim as raw bytes.
      # The whole answer is read, within its cap, before anything is written
      # back, so a response cut short upstream is a 502 rather than a truncated
      # success.
      result = @transport.call(Net::HTTP::Post, @ingest, headers, body)
      # The API answers 2xx, 4xx or 5xx. A redirect is never followed, and
      # anything outside 200 to 599 is not a status a browser can be handed.
      unless RELAYABLE_STATUS.cover?(result.status) && !(300..399).cover?(result.status)
        return upstream_failed(env, 502, "Bad gateway", "upstream answered an unusable status",
                               cors)
      end

      relay(result, cors)
    rescue TimeoutError => e
      upstream_failed(env, 504, "Gateway timeout", e, cors)
    rescue Error => e
      # Refused, reset, unresolvable, malformed, truncated, or over the cap.
      upstream_failed(env, 502, "Bad gateway", e, cors)
    end

    # What the callback returned, when it is exactly one IP address.
    #
    # Anything else means client_ip is wired up wrongly, and forwarding a
    # wrong address would mis-score every visitor, so nothing is sent.
    def client_address(env, request)
      address = begin
        @client_ip.call(request)
      rescue StandardError => e
        e
      end
      return address if Config.ip_literal?(address)

      misconfigured(env, address)
      nil
    end

    def misconfigured(env, returned)
      first = @misconfigured_lock.synchronize do
        next false unless @misconfigured.empty?

        @misconfigured << true
      end
      return unless first

      shown = returned.is_a?(Exception) ? "raised #{returned.class}" : "returned #{returned.class}"
      log(env, "fingerly proxy: client_ip #{shown}, not one IP address; " \
               "no identification is forwarded until it does (logged once)")
    end

    # Answers a failed upstream call and logs one line about it: no stack
    # trace, nothing from the request, and nothing in the response that names
    # Fingerly.
    # The line names the failure kind only, never the upstream host, port, URL
    # or a key.
    def upstream_failed(env, status, message, error, cors = {})
      reason = error.is_a?(Exception) ? error.message : error.to_s
      log(env, "fingerly proxy: #{status} #{reason}")
      refuse(status, message, cors)
    end

    def log(env, line)
      logger = @logger || env["rack.logger"]
      logger ? logger.warn(line) : warn(line)
    rescue StandardError
      # A broken logger must not turn a gateway error into a crash.
      nil
    end

    # Checks the browser's key before anything is forwarded.
    #
    # The browser must present a public key, +fly_pk_…+, for the proxy key's
    # environment; the proxy forwards it alongside its own. A secret key, a
    # proxy key, a public key of another environment or anything else is
    # refused, so no credential but a public key ever travels upstream as
    # +X-API-Key+.
    #
    # @return [String, nil] the public key to forward, or nil when unauthorised
    def upstream_key_for(presented)
      browser = Config.scope_for(presented, Config::PUBLIC)
      return nil if browser.nil?

      browser == @scope ? presented : nil
    end

    # Builds the headers for the forwarded request.
    #
    # Nothing is copied wholesale: all incoming +x-fingerly-*+, +cookie+ and
    # +authorization+ headers are stripped. +x-fingerly-origin+ is sent when
    # incoming +origin+ is non-empty (never synthesized from +host+ or the
    # request URL); otherwise a validated +x-fingerly-sdk-platform+ is restored.
    #
    # @return [Hash]
    def upstream_headers(request, api_key, address, origin, sdk_platform)
      headers = {
        "content-type" => non_blank(safe(request.header("content-type"))) || "application/json",
        "x-api-key" => api_key,
        "x-fingerly-client-ip" => address,
        "x-fingerly-user-agent" => safe(request.header("user-agent")).to_s,
        "x-fingerly-proxy-version" => PROXY_VERSION,
        "user-agent" => USER_AGENT
      }
      # One channel only. The API refuses a proxied request that carries both,
      # and a browser Origin wins, as it does for a request sent directly.
      if origin
        headers["x-fingerly-origin"] = origin
      elsif sdk_platform
        headers["x-fingerly-sdk-platform"] = sdk_platform
      end
      host = non_blank(safe(request.header("host")))
      headers["x-fingerly-host"] = host if host
      headers["x-fingerly-proxy-key"] = @key
      FORWARDED_CLIENT_HEADERS.each do |name|
        value = non_blank(safe(request.header(name)))
        headers[name] = value if value
      end
      SIGNATURE_HEADERS.each do |name|
        value = non_blank(safe(request.header(name)))
        headers[name] = value if value && value.bytesize <= MAX_SIGNATURE_HEADER_BYTES
      end
      headers
    end

    # Drops a visitor-supplied value that could not go in a header.
    def safe(value)
      Config.header_safe?(value) ? value : nil
    end

    def non_blank(value)
      value && !value.strip.empty? ? value : nil
    end

    def validated_platform(value)
      value if Config.header_safe?(value) && ALLOWED_PLATFORMS.match?(value)
    end

    def normalize_origins(origins)
      Array(origins).filter_map do |origin|
        candidate = origin.to_s.strip
        candidate if !candidate.empty? && Config.header_safe?(candidate)
      end.uniq.freeze
    end

    def cors_headers(origin)
      return {} unless origin && @allowed_origins.include?(origin)

      {
        "access-control-allow-origin" => origin,
        "vary" => "Origin",
        "access-control-allow-methods" => "POST, OPTIONS",
        "access-control-allow-headers" =>
          "content-type, x-api-key, idempotency-key, x-fingerly-sdk-platform",
        "access-control-expose-headers" =>
          "x-request-id, ratelimit-limit, ratelimit-remaining, retry-after"
      }
    end

    def preflight(origin, cors)
      return refuse(403, "Forbidden") if origin && cors.empty?

      headers = { "cache-control" => "no-store", "allow" => "POST, OPTIONS" }.merge(cors)
      [204, headers, []]
    end

    # Returns the upstream response, uncacheable and with only the allowlisted
    # headers.
    #
    # Header names are lowercase and repeats joined with ", ", which is the
    # one shape Rack 2 and Rack 3 both accept: Rack 3 refuses an uppercase name
    # outright, and Rack 2 refuses the array Rack 3 would rather have.
    def relay(result, cors = {})
      headers = { "cache-control" => "no-store" }.merge(cors)
      result.headers.each do |name, values|
        key = name.downcase
        next unless RELAYED_HEADERS.include?(key)

        filtered = Array(values).select { |v| Config.header_safe?(v) && !v.match?(/fingerly/i) }
        headers[key] = filtered.join(", ") unless filtered.empty?
      end

      if BODILESS.include?(result.status)
        headers.delete("content-type")
        return [result.status, headers, []]
      end

      [result.status, headers, [result.body]]
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

    # A JSON refusal that never reached Fingerly.
    def json_refuse(status, body, extra = {})
      headers = { "content-type" => "application/json", "cache-control" => "no-store" }
      [status, headers.merge(extra), [body]]
    end
  end
end
