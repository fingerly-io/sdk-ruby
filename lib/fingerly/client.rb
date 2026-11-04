# frozen_string_literal: true

require "json"
require "net/http"
require "time"

module Fingerly
  # Reads events for one organization and environment.
  #
  # Build one and reuse it: it keeps a connection per thread and is safe to
  # share. Secret keys and webhook secrets belong in server-side code only; a
  # browser must never see either.
  #
  #   fingerly = Fingerly::Client.new(secret_key: ENV.fetch("FINGERLY_SECRET_KEY"))
  #   event = fingerly.events.get(request_id)
  class Client
    include Redacted

    DEFAULT_TIMEOUT = 10
    DEFAULT_API_VERSION = "v1"
    USER_AGENT = "fingerly-ruby/#{VERSION}".freeze

    # An error body is small; anything larger is not one worth reading.
    MAX_ERROR_BODY = 1 << 20

    # @return [Events] event reads under this client's secret key
    attr_reader :events

    # @param secret_key [String] a server-only key,
    #   +fly_sk_{environment}_…+, whose prefix names the environment read
    # @param endpoint [String, nil] overrides the Fingerly API origin, for a
    #   local or self-hosted API
    # @param api_version [String] the API route version
    # @param timeout [Numeric] the deadline for each request in seconds,
    #   covering the response body
    # @param configure_http [Proc, nil] receives the +Net::HTTP+ before it
    #   connects, for a proxy or a custom TLS setup. Timeouts set there are
    #   replaced: the deadline belongs to this client.
    # @raise [ConfigurationError] if a key, endpoint, version or timeout is
    #   invalid. Nothing is sent until then.
    def initialize(secret_key:, endpoint: nil, api_version: DEFAULT_API_VERSION,
                   timeout: DEFAULT_TIMEOUT, configure_http: nil)
      # The key is validated even when an endpoint is given, so a public, proxy
      # or management key can never reach an API that would accept it.
      Config.parse_key(secret_key, Config::SECRET)
      origin = Config.normalize_endpoint(endpoint || Config::DEFAULT_ENDPOINT)

      @secret_key = secret_key
      @origin = origin
      @base_path = "/api/#{Config.normalize_api_version(api_version)}"
      @transport = Transport.new(
        origin: origin,
        timeout: Config.positive_seconds(timeout, "timeout"),
        configure_http: configure_http
      )
      @events = Events.new(self)
      freeze
    end

    # Releases this thread's connection to Fingerly.
    #
    # Reusing the client afterwards simply opens another one, so this is for a
    # script that is finished rather than something a server needs to call.
    def close
      @transport.close
    end

    # Performs one authenticated GET and returns the decoded body.
    #
    # Never retries a delivered request, and the deadline covers reading the
    # body.
    #
    # @api private
    def get(path)
      result = @transport.call(
        Net::HTTP::Get, @base_path + path,
        "x-api-key" => @secret_key,
        "accept" => "application/json",
        "user-agent" => USER_AGENT
      )
      raise api_error(result) unless (200..299).cover?(result.status)

      decode(result.body)
    end

    private

    def redacted_fields
      [["endpoint", @origin + @base_path], ["secret_key", Redacted::MARK]]
    end

    # @raise [Error] if the body is not JSON, which means it did not come from
    #   the Fingerly API
    def decode(body)
      parsed = JSON.parse(body)
      return parsed if parsed.is_a?(Hash)

      raise Error, "Fingerly API returned a body that is not an object"
    rescue JSON::ParserError
      raise Error, "Fingerly API returned a body that is not JSON"
    end

    # Maps a failed response to a redacted APIError.
    #
    # Only the status and the structured fields the API documents are
    # surfaced. The raw body is deliberately dropped rather than echoed.
    def api_error(result)
      envelope = error_envelope(result.body)
      error = envelope["error"]
      error = {} unless error.is_a?(Hash)

      APIError.new(
        status: result.status,
        code: redact(error["code"]),
        # Redacting the rendered JSON covers nested values without walking the
        # tree.
        details: error.key?("details") ? redact_tree(error["details"]) : nil,
        request_id: redact(envelope["request_id"] || header(result, "x-request-id")),
        retry_after: retry_after(header(result, "retry-after"))
      )
    end

    def header(result, name)
      value = Array(result.headers[name]).first
      value.is_a?(String) && !value.empty? ? value : nil
    end

    # Retry-After is either whole seconds or an HTTP date.
    #
    # @return [Integer, nil] seconds from now, never negative
    def retry_after(value)
      return nil if value.nil?
      return Integer(value, 10) if value.match?(/\A\d{1,10}\z/)

      [(Time.httpdate(value) - Time.now).ceil, 0].max
    rescue ArgumentError
      nil
    end

    def error_envelope(body)
      return {} if body.empty? || body.bytesize > MAX_ERROR_BODY

      parsed = JSON.parse(body)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      # A non-JSON body still reports its HTTP status.
      {}
    end

    def redact(value)
      value.is_a?(String) ? value.gsub(@secret_key, "[redacted]") : value
    end

    def redact_tree(value)
      return nil if value.nil?

      # Any JSON value is legal at the top level, so a details field that is a
      # bare string or number survives the round trip too. quirks_mode is not
      # passed: the json gem dropped the keyword in 3.0, and it has not been
      # needed since 2.0.
      JSON.parse(JSON.generate(value).gsub(@secret_key, "[redacted]"))
    rescue JSON::ParserError, JSON::GeneratorError
      nil
    end
  end

  # Reads events stored for the organization and environment of the client's
  # secret key. Reached as +fingerly.events+.
  class Events
    include Redacted

    # @api private
    def initialize(client)
      @client = client
      freeze
    end

    # Fetches one event by request id.
    #
    # @param request_id [String] the +request_id+ returned by identification
    # @return [Event]
    # @raise [APIError] on any non-2xx response. An event is readable as soon
    #   as identification answers, so +404 event_not_found+ means a request id
    #   that was never issued.
    # @raise [TimeoutError] if the request exceeds the client timeout
    def get(request_id)
      raise ConfigurationError, "request_id is required" if request_id.to_s.empty?

      Event.new(@client.get("/events/#{Events.escape(request_id)}"))
    end

    # Lists events within the retention window, newest first.
    #
    # An unset filter is not sent, so the server applies its own default.
    #
    # @param from [Time, nil] start of the window; defaults to 24 hours ago,
    #   and may be at most 30 days wide and start at most 30 days ago
    # @param to [Time, nil] end of the window; defaults to now
    # @param page [Integer, nil] one-based page number
    # @param limit [Integer, nil] rows per page; the server caps it at 200
    # @param visitor [String, nil] restricts the listing to one exact visitor
    # @param level [String, nil] restricts it to +low+, +medium+ or +high+
    # @return [EventPage]
    # @raise [APIError] on any non-2xx response
    def list(from: nil, to: nil, page: nil, limit: nil, visitor: nil, level: nil)
      query = {
        "from" => from && Events.instant(from),
        "to" => to && Events.instant(to),
        "page" => page && Config.positive_int(page, "page"),
        "limit" => limit && Config.positive_int(limit, "limit"),
        "visitor" => visitor,
        "level" => level
      }.compact

      suffix = query.empty? ? "" : "?#{URI.encode_www_form(query)}"
      EventPage.new(@client.get("/events#{suffix}"))
    end

    # Percent-encodes a request id into exactly one path segment.
    #
    # Only RFC 3986 unreserved characters survive, so a slash cannot escape the
    # segment and a space cannot become a +.
    #
    # @api private
    def self.escape(value)
      value.to_s.gsub(/[^A-Za-z0-9\-._~]/) do |char|
        char.bytes.map { |byte| format("%%%02X", byte) }.join
      end
    end

    # The API accepts RFC 3339 only, and reads it as an absolute instant.
    #
    # @api private
    def self.instant(value)
      raise ConfigurationError, "from and to must be Time values" unless value.is_a?(Time)

      value.utc.iso8601(3)
    end

    private

    def redacted_fields
      []
    end
  end
end
