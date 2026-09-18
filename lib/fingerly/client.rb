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
    DEFAULT_TIMEOUT = 10
    DEFAULT_API_VERSION = "v1"
    USER_AGENT = "fingerly-ruby/#{VERSION}".freeze

    # An error body is small; anything larger is not one worth reading.
    MAX_ERROR_BODY = 1 << 20

    # @return [Events] event reads under this client's secret key
    attr_reader :events

    # @param secret_key [String] a server-only key,
    #   +fly_sk_{eu|us}_{environment}_…+, whose prefix selects the regional API
    #   and the environment read
    # @param endpoint [String, nil] overrides the regional origin implied by
    #   the key, for a local or self-hosted API
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
      scope = Config.parse_key(secret_key, Config::SECRET)
      origin = Config.normalize_endpoint(endpoint || scope.origin)

      @secret_key = secret_key
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
        request_id: redact(envelope["request_id"])
      )
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
    DEFAULT_WAIT_TIMEOUT = 10
    DEFAULT_POLL_INTERVAL = 0.25

    # @api private
    def initialize(client)
      @client = client
      freeze
    end

    # Fetches one event by request id.
    #
    # @param request_id [String] the +request_id+ returned by identification
    # @return [Event]
    # @raise [APIError] on any non-2xx response. An event that has not been
    #   archived yet gives +404 event_not_found+; use {#wait_for} right after
    #   identifying a visitor.
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

    # Polls until a newly identified event becomes readable.
    #
    # Identification answers before the event is archived, so reach for this
    # only when you have just identified a visitor. Only a structured
    # +404 event_not_found+ is retried; every other failure is raised at once.
    #
    # @param request_id [String] the +request_id+ returned by identification
    # @param timeout [Numeric] the total time to keep polling, in seconds
    # @param interval [Numeric] the delay between polls, in seconds
    # @return [Event]
    # @raise [TimeoutError] if the event is still missing at the deadline. The
    #   last {APIError} is kept as the +cause+, so the reason it kept waiting
    #   is not lost.
    # @raise [ConfigurationError] if a bound is not positive
    def wait_for(request_id, timeout: DEFAULT_WAIT_TIMEOUT, interval: DEFAULT_POLL_INTERVAL)
      Config.positive_seconds(timeout, "timeout")
      Config.positive_seconds(interval, "interval")

      deadline = Events.monotonic + timeout
      last_miss = nil
      loop do
        begin
          return get(request_id)
        rescue APIError => e
          raise unless e.event_not_found?

          last_miss = e
        end

        # Stop rather than sleep past the deadline for a poll that could not
        # run before it.
        if deadline - Events.monotonic <= interval
          raise TimeoutError.new("Timed out waiting for event #{request_id}"), cause: last_miss
        end

        sleep interval
      end
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

    # @api private
    def self.monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
