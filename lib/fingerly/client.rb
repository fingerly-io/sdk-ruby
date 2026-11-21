# frozen_string_literal: true

require "json"
require "net/http"
require "time"

module Fingerly
  # Reads events for one organization and environment.
  #
  # Build one and reuse it: it is safe to share between threads and fibers,
  # and connections come from one pool per process. Secret keys and webhook
  # secrets belong in server-side code only; a browser must never see either.
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

    # @return [DeviceCheck] the DeviceCheck bits of iOS events, read or
    #   written once per event
    attr_reader :device_check

    # @return [Agents] reports of the requests your server served, answered
    #   with what sent each one. {AgentSightings} uses it for you.
    attr_reader :agents

    # @param secret_key [String] a server-only key,
    #   +fly_sk_{environment}_…+, whose prefix names the environment read
    # @param endpoint [String, nil] overrides the Fingerly API origin: a bare
    #   origin, scheme, host and optional port, and +https+ only
    # @param allow_insecure_loopback [Boolean] lets +endpoint+ be a plain
    #   +http+ origin on 127.0.0.1, localhost or [::1], for local development
    #   and tests. Off by default.
    # @param api_version [String] the API route version
    # @param timeout [Numeric] the deadline for each request in seconds,
    #   covering the response body
    # @param configure_http [Proc, nil] receives the +Net::HTTP+ before it
    #   connects, for a proxy or a custom TLS setup. Timeouts set there are
    #   replaced: the deadline belongs to this client.
    # @raise [ConfigurationError] if a key, endpoint, version or timeout is
    #   invalid. Nothing is sent until then.
    def initialize(secret_key:, endpoint: nil, api_version: DEFAULT_API_VERSION,
                   timeout: DEFAULT_TIMEOUT, configure_http: nil, allow_insecure_loopback: false)
      # The key is validated even when an endpoint is given, so a public, proxy
      # or management key can never reach an API that would accept it.
      Config.parse_key(secret_key, Config::SECRET)
      origin = Config.normalize_origin(endpoint || Config::DEFAULT_ENDPOINT, "endpoint",
                                       allow_insecure_loopback: allow_insecure_loopback == true)

      @secret_key = secret_key
      @origin = origin
      @base_path = "/api/#{Config.normalize_api_version(api_version)}"
      @transport = Transport.new(
        origin: origin,
        timeout: Config.positive_seconds(timeout, "timeout"),
        configure_http: configure_http
      )
      @events = Events.new(self)
      @device_check = DeviceCheck.new(self)
      @agents = Agents.new(self)
      freeze
    end

    # Closes the idle connections to this client's destination, which every
    # client and proxy in the process shares.
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

    # Performs one authenticated DeviceCheck spend and returns the decoded
    # body.
    #
    # A held DeviceCheck token may be retried only with the same request, so a
    # +503+ or a transport failure is retried with exactly these bytes, at
    # most {DEVICE_CHECK_ATTEMPTS} times in all. Nothing else is retried.
    #
    # @param method [Class] +Net::HTTP::Post+ or +Net::HTTP::Put+
    # @param body [String, nil] the JSON body, or nil for none
    # @api private
    def spend_device_check(method, path, body)
      headers = {
        "x-api-key" => @secret_key,
        "accept" => "application/json",
        "user-agent" => USER_AGENT
      }
      if body
        headers["content-type"] = "application/json"
      else
        # No body at all, stated, so nothing in between waits for one.
        headers["content-length"] = "0"
      end
      headers.freeze

      result = with_device_check_retries do
        @transport.call(method, @base_path + path, headers, body)
      end
      raise device_check_error(result) unless (200..299).cover?(result.status)

      decode(result.body)
    end

    # Performs one authenticated consume, a POST with no body, and returns
    # the decoded body.
    #
    # Never retried, like a read.
    #
    # @raise [EventAlreadyConsumedError] on +409 event_already_consumed+
    # @raise [APIError] on any other non-2xx response
    # @api private
    def post_consume(path)
      result = @transport.call(
        Net::HTTP::Post, @base_path + path,
        {
          "x-api-key" => @secret_key,
          "accept" => "application/json",
          "user-agent" => USER_AGENT,
          # No body at all, stated, so nothing in between waits for one.
          "content-length" => "0"
        }.freeze,
        nil
      )
      raise consume_error(result) unless (200..299).cover?(result.status)

      decode(result.body)
    end

    # Performs one authenticated JSON POST and returns the decoded body.
    #
    # Never retried: the caller decides what a failure means.
    #
    # @raise [APIError] on any non-2xx response
    # @api private
    def post_json(path, body)
      result = @transport.call(
        Net::HTTP::Post, @base_path + path,
        {
          "x-api-key" => @secret_key,
          "accept" => "application/json",
          "content-type" => "application/json",
          "user-agent" => USER_AGENT
        }.freeze,
        body
      )
      raise api_error(result) unless (200..299).cover?(result.status)

      decode(result.body)
    end

    # Attempts in all for one DeviceCheck spend, the first included.
    DEVICE_CHECK_ATTEMPTS = 3

    # Seconds to wait before each retry, when the answer named no
    # +Retry-After+.
    DEVICE_CHECK_BACKOFF = [0.25, 0.5].freeze

    # The longest +Retry-After+ honoured between attempts.
    DEVICE_CHECK_MAX_WAIT = 2

    private

    def with_device_check_retries
      attempt = 0
      loop do
        attempt += 1
        last = attempt >= DEVICE_CHECK_ATTEMPTS
        begin
          result = yield
        rescue TimeoutError, ConnectionError
          raise if last

          sleep DEVICE_CHECK_BACKOFF[attempt - 1]
          next
        end
        return result unless result.status == 503 && !last

        wait = retry_after(header(result, "retry-after"))
        sleep(wait ? [wait, DEVICE_CHECK_MAX_WAIT].min : DEVICE_CHECK_BACKOFF[attempt - 1])
      end
    end

    def device_check_error(result)
      error = api_error(result)
      DeviceCheckError.new(
        status: error.status, code: error.code, details: error.details,
        request_id: error.request_id, retry_after: error.retry_after
      )
    end

    # The already-consumed answer's shape is read tolerantly: its code from
    # the error envelope or the top level, and its +consumed_at+ from the top
    # level, the envelope, or a +details+ entry.
    def consume_error(result)
      error = api_error(result)
      envelope = error_envelope(result.body)
      code = error.code || (envelope["code"].is_a?(String) ? redact(envelope["code"]) : nil)
      return error unless result.status == 409 && code == EventAlreadyConsumedError::CODE

      EventAlreadyConsumedError.new(
        status: error.status, code: code, details: error.details,
        request_id: error.request_id, retry_after: error.retry_after,
        consumed_at: consumed_at(envelope, error.details)
      )
    end

    def consumed_at(envelope, details)
      nested = envelope["error"].is_a?(Hash) ? envelope["error"]["consumed_at"] : nil
      entry = details.is_a?(Array) &&
              details.find { |item| item.is_a?(Hash) && item["field"] == "consumed_at" }
      found = [envelope["consumed_at"], nested, entry && entry["issue"]].find do |value|
        value.is_a?(String) && !value.empty?
      end
      redact(found)
    end

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
        retry_after: retry_after(header(result, "retry-after")),
        rate_limit_scope: redact(header(result, "fingerly-ratelimit-scope"))
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
    # @raise [APIError] on any non-2xx response. +404 event_pending+
    #   ({APIError#pending?}) means the event was accepted and is still being
    #   recorded: retry after {APIError#retry_after} seconds.
    #   +404 event_not_found+ means a request id that was never issued, or one
    #   past retention.
    # @raise [TimeoutError] if the request exceeds the client timeout
    def get(request_id)
      Event.new(@client.get("/events/#{Events.segment(request_id)}"))
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
    # @param kind [String, nil] restricts it to one visitor kind, such as
    #   +ai_bot+; see {VisitorKind}. The server rejects a kind it does not know.
    # @param ai_provider [String, nil] restricts it to AI agents from one
    #   operator, exactly as events name it in {AiAgent#provider}, such as
    #   +OpenAI+; the match is case-sensitive
    # @param ai_purpose [String, nil] restricts it to AI agents with one
    #   purpose, such as +user_fetch+; see {AiPurpose}. The server rejects a
    #   purpose it does not know.
    # @return [EventPage]
    # @raise [APIError] on any non-2xx response
    def list(from: nil, to: nil, page: nil, limit: nil, visitor: nil, level: nil,
             kind: nil, ai_provider: nil, ai_purpose: nil)
      query = {
        "from" => from && Events.instant(from),
        "to" => to && Events.instant(to),
        "page" => page && Config.positive_int(page, "page"),
        "limit" => limit && Config.positive_int(limit, "limit"),
        "visitor" => visitor,
        "level" => level,
        "kind" => kind,
        "ai_provider" => ai_provider,
        "ai_purpose" => ai_purpose
      }.compact

      suffix = query.empty? ? "" : "?#{URI.encode_www_form(query)}"
      EventPage.new(@client.get("/events#{suffix}"))
    end

    # The age past which {#verify} answers +too_old+, in seconds.
    DEFAULT_MAX_AGE_SECONDS = 300

    # Marks an event consumed, once. Every later call for the same event
    # raises {EventAlreadyConsumedError}, so one event backs one decision.
    #
    # Never retried.
    #
    # @param request_id [String] the +request_id+ returned by identification
    # @return [EventConsumption]
    # @raise [EventAlreadyConsumedError] when the event was already consumed;
    #   see {EventAlreadyConsumedError#consumed_at}
    # @raise [APIError] on any other non-2xx response, such as
    #   +404 event_not_found+
    # @raise [TimeoutError] if the request exceeds the client timeout
    def consume(request_id)
      EventConsumption.new(@client.post_consume(consume_path(Events.segment(request_id))))
    end

    # Reads an event and checks it can back a backend action, then consumes
    # it.
    #
    # The checks run in this order and stop at the first failure, which
    # becomes {EventVerification#reason}: +not_found+, +too_old+ (older than
    # +max_age_seconds+, or with no readable +occurred_at+), +tag_mismatch+
    # (only when +tag+ is given), +unidentifiable+ (empty +visitor_id+),
    # +unscored+ (no +suspect_score+), then +already_consumed+ from the
    # consume, which runs last and only when everything else passed. The score
    # itself is never judged: that policy is the caller's.
    #
    # @param request_id [String] the +request_id+ returned by identification
    # @param max_age_seconds [Integer] the oldest event accepted, in seconds
    # @param tag [String, nil] the tag the event must carry exactly; nil
    #   skips the check
    # @param consume [Boolean] false skips the consume
    # @return [EventVerification]
    # @raise [ConfigurationError] for an invalid option or request id; nothing
    #   is sent
    # @raise [APIError] for any failure other than +404 event_not_found+ and
    #   +409 event_already_consumed+, +404 event_pending+ included: a pending
    #   event is not a verdict
    # @raise [TimeoutError, ConnectionError] as for {#get}
    def verify(request_id, max_age_seconds: DEFAULT_MAX_AGE_SECONDS, tag: nil, consume: true)
      Events.verify_options(max_age_seconds, tag, consume)
      segment = Events.segment(request_id)

      begin
        payload = @client.get("/events/#{segment}")
      rescue APIError => e
        raise unless e.event_not_found?

        return EventVerification.new(reason: EventVerification::NOT_FOUND, event: nil)
      end

      event = Event.new(payload, lenient_time: true)
      reason = Events.failed_check(event, max_age_seconds, tag)
      return EventVerification.new(reason: reason || "", event: event) if reason || !consume

      begin
        @client.post_consume(consume_path(segment))
      rescue EventAlreadyConsumedError
        return EventVerification.new(reason: EventVerification::ALREADY_CONSUMED, event: event)
      rescue APIError => e
        raise unless e.event_not_found?

        return EventVerification.new(reason: EventVerification::NOT_FOUND, event: nil)
      end
      EventVerification.new(reason: "", event: event)
    end

    # @raise [ConfigurationError] for an option {#verify} cannot apply
    # @api private
    def self.verify_options(max_age_seconds, tag, consume)
      unless max_age_seconds.is_a?(Integer) && max_age_seconds.positive?
        raise ConfigurationError, "max_age_seconds must be a positive Integer"
      end
      # An empty tag would match every untagged event, so it is refused rather
      # than read as no check.
      unless tag.nil? || (tag.is_a?(String) && !tag.empty?)
        raise ConfigurationError, "tag must be a non-empty String or nil"
      end
      return if [true, false].include?(consume)

      raise ConfigurationError, "consume must be true or false"
    end

    # The first check {#verify} fails before the consume, or nil.
    #
    # @api private
    def self.failed_check(event, max_age_seconds, tag)
      occurred_at = event.occurred_at
      # A future time passes; a missing or unreadable one fails closed.
      if occurred_at.nil? || Time.now - occurred_at > max_age_seconds
        return EventVerification::TOO_OLD
      end

      return EventVerification::TAG_MISMATCH if tag && (event.tag || "") != tag
      return EventVerification::UNIDENTIFIABLE if event.visitor_id.nil? || event.visitor_id.empty?
      return EventVerification::UNSCORED unless event.scored?

      nil
    end

    # A request id as one escaped path segment.
    #
    # @raise [ConfigurationError] for an id no escaping can keep in its segment
    # @api private
    def self.segment(request_id)
      # URL parsers resolve a dot segment even when it is percent-encoded, so
      # escaping cannot keep these in the path: "." and the empty id would name
      # the list route, and ".." a route above it, secret key attached.
      if ["", ".", ".."].include?(request_id.to_s)
        raise ConfigurationError, "request_id is not a Fingerly request id"
      end

      escape(request_id)
    end

    # Percent-encodes a request id into exactly one path segment.
    #
    # Only RFC 3986 unreserved characters survive, so a slash cannot escape the
    # segment and a space cannot become a +.
    #
    # @api private
    def self.escape(value)
      # Byte by byte, so an id that is not valid UTF-8 is escaped like any
      # other rather than raising from the regular expression.
      value.to_s.b.gsub(/[^A-Za-z0-9\-._~]/n) { |byte| format("%%%02X", byte.ord) }
    end

    # The API accepts RFC 3339 only, and reads it as an absolute instant.
    #
    # @api private
    def self.instant(value)
      raise ConfigurationError, "from and to must be Time values" unless value.is_a?(Time)

      # getutc, because Time#utc converts the caller's own object in place and
      # raises on a frozen one.
      value.getutc.iso8601(3)
    end

    private

    def consume_path(segment)
      "/events/#{segment}/consume"
    end

    def redacted_fields
      []
    end
  end

  # Reads or writes Apple's two DeviceCheck bits for the device behind an iOS
  # event. Reached as +fingerly.device_check+.
  #
  # Fingerly holds the DeviceCheck token that came with an identification for
  # one hour, and spends it once: a read or a write, never both. Apple treats
  # each token as single-use, so a flow that reads and then marks a device,
  # such as a once-per-device free trial, reads on one identification and
  # writes on the next.
  #
  # A +503+ (+device_check_unavailable+) or a transport failure is retried
  # with the same request; Apple lets a token be retried only that way, and
  # the API answers +409 device_check_spent+ to a retry that differs.
  #
  #   bits = fingerly.device_check.query(request_id)
  #   fingerly.device_check.write(next_request_id, bit0: true) unless bits.bit0
  class DeviceCheck
    include Redacted

    # @api private
    def initialize(client)
      @client = client
      freeze
    end

    # Spends the event's held token to read the device's two bits.
    #
    # @param request_id [String] the +request_id+ of an iOS identification
    #   made within the last hour
    # @return [DeviceCheckBits]
    # @raise [DeviceCheckError] on any non-2xx response; its predicates name
    #   the documented codes
    # @raise [TimeoutError, ConnectionError] when every attempt failed to get
    #   an answer
    def query(request_id)
      DeviceCheckBits.new(
        @client.spend_device_check(Net::HTTP::Post, "#{path(request_id)}/query", nil)
      )
    end

    # Spends the event's held token to set +bit0+, +bit1+ or both. A bit left
    # nil keeps its value.
    #
    # @param request_id [String] the +request_id+ of an iOS identification
    #   made within the last hour
    # @param bit0 [Boolean, nil] the value for the first bit
    # @param bit1 [Boolean, nil] the value for the second bit
    # @return [DeviceCheckWrite] the bits Apple accepted
    # @raise [ConfigurationError] when neither bit is given, or a bit is not
    #   true, false or nil; nothing is sent
    # @raise [DeviceCheckError] on any non-2xx response
    # @raise [TimeoutError, ConnectionError] when every attempt failed to get
    #   an answer
    def write(request_id, bit0: nil, bit1: nil)
      bits = { "bit0" => bit0, "bit1" => bit1 }.compact
      raise ConfigurationError, "name bit0, bit1 or both" if bits.empty?
      unless bits.values.all? { |value| [true, false].include?(value) }
        raise ConfigurationError, "bit0 and bit1 must be true, false or nil"
      end

      DeviceCheckWrite.new(
        @client.spend_device_check(Net::HTTP::Put, path(request_id), JSON.generate(bits))
      )
    end

    private

    def path(request_id)
      "/events/#{Events.segment(request_id)}/device-check"
    end

    def redacted_fields
      []
    end
  end

  # Reports the requests your server served, as raw input, and answers what
  # sent each one. Reached as +fingerly.agents+.
  #
  # AI crawlers and fetchers that never run a page's JavaScript are seen only
  # this way. {AgentSightings} batches, counts and remembers these answers for
  # you; call this directly only to build that yourself.
  class Agents
    include Redacted

    # The most requests one call may report.
    MAX_SIGHTINGS = 200

    # @api private
    def initialize(client)
      @client = client
      freeze
    end

    # Reports up to {MAX_SIGHTINGS} requests in one call.
    #
    # Never retried: a call the server may have counted must not be counted
    # twice.
    #
    # @param items [Array<AgentSightingInput>] the requests, answered in the
    #   same order
    # @return [AgentSightingsReport]
    # @raise [ConfigurationError] for no items, more than {MAX_SIGHTINGS}, or
    #   an item that is not an {AgentSightingInput}; nothing is sent
    # @raise [APIError] on any non-2xx response: +429+ carries
    #   {APIError#retry_after} and {APIError#rate_limit_scope}
    # @raise [TimeoutError, ConnectionError] when no answer arrived
    def report_sightings(items)
      unless items.is_a?(Array) && (1..MAX_SIGHTINGS).cover?(items.size) &&
             items.all?(AgentSightingInput)
        raise ConfigurationError,
              "items must be 1 to #{MAX_SIGHTINGS} Fingerly::AgentSightingInput values"
      end

      body = JSON.generate({ "items" => items.map { |item| Agents.wire(item) } })
      AgentSightingsReport.new(@client.post_json("/agents/sightings", body))
    end

    # One item as JSON can carry it: a header that is not valid UTF-8 has its
    # bad bytes replaced, since JSON strings are Unicode.
    #
    # @api private
    def self.wire(item)
      item.to_h.transform_values do |value|
        next value unless value.is_a?(String)

        text = value.dup.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : text.scrub
      end
    end

    private

    def redacted_fields
      []
    end
  end
end
