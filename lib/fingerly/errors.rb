# frozen_string_literal: true

module Fingerly
  # Base class for every failure this SDK raises at run time.
  #
  # A bad option raises {ConfigurationError} instead, which is an
  # +ArgumentError+: a key that was never valid is a programming mistake, not
  # something a retry or a rescue around the call site can help with.
  class Error < StandardError; end

  # Raised when a credential, route, limit or callback is unusable.
  #
  # It derives from +ArgumentError+, so ordinary Ruby handling applies, and it
  # is raised while the client or proxy is being built, before any network
  # access.
  class ConfigurationError < ArgumentError; end

  # Raised for any non-2xx response from the Fingerly API.
  #
  # The message carries only the HTTP status. Response bodies are never
  # echoed, and any occurrence of the secret key in the metadata is redacted.
  #
  #   begin
  #     event = fingerly.events.get(request_id)
  #   rescue Fingerly::APIError => e
  #     return "retry" if e.pending? # not recorded yet: retry after e.retry_after
  #     return "refuse" if e.event_not_found?
  #     raise
  #   end
  class APIError < Error
    # @return [Integer] the HTTP status code
    attr_reader :status

    # @return [String, nil] the stable machine-readable code, such as
    #   +event_not_found+
    attr_reader :code

    # @return [Object, nil] extra context from the error body; its shape
    #   depends on {#code}
    attr_reader :details

    # @return [String, nil] the server-side trace id to quote in support
    #   requests
    attr_reader :request_id

    # @return [Integer, nil] seconds to wait before trying again, from the
    #   +Retry-After+ header, or nil when the response carried none. Sent with
    #   429, +404 event_pending+ and some 503 answers; the SDK never retries by
    #   itself.
    attr_reader :retry_after

    # @return [String, nil] which limit refused the call, from the
    #   +Fingerly-RateLimit-Scope+ header of a 429, such as +daily+ for an
    #   organization's daily allowance; see {RATE_LIMIT_SCOPE_DAILY}
    attr_reader :rate_limit_scope

    # The +Fingerly-RateLimit-Scope+ of a daily allowance: it resets at the
    # next UTC day.
    RATE_LIMIT_SCOPE_DAILY = "daily"

    # @api private
    def initialize(status:, code: nil, details: nil, request_id: nil, retry_after: nil,
                   rate_limit_scope: nil)
      @status = status
      @code = code
      @details = details
      @request_id = request_id
      @retry_after = retry_after
      @rate_limit_scope = rate_limit_scope
      described = "Fingerly API returned HTTP #{status}"
      super(code ? "#{described} (#{code})" : described)
    end

    # Whether this is a read for an event that does not exist: a request id
    # that was never issued, or one past retention.
    #
    # It is false for {#pending?}: that event exists and is still being
    # recorded.
    #
    # @return [Boolean]
    def event_not_found?
      status == 404 && code == "event_not_found"
    end

    # Whether this is a read for an event the API accepted but has not
    # recorded yet (+404 event_pending+).
    #
    # Nothing is decided yet: read again after {#retry_after} seconds, or
    # verify asynchronously. The SDK never retries by itself.
    #
    # @return [Boolean]
    def pending?
      status == 404 && code == "event_pending"
    end

    # Whether this is a consume for an event that was already consumed
    # (+409 event_already_consumed+). Such an answer raises
    # {EventAlreadyConsumedError}.
    #
    # @return [Boolean]
    def event_already_consumed?
      status == 409 && code == EventAlreadyConsumedError::CODE
    end
  end

  # Raised when +fingerly.events.consume+ finds the event already consumed
  # (+409 event_already_consumed+).
  #
  # It is an {APIError}, so +rescue Fingerly::APIError+ still catches it.
  #
  #   begin
  #     fingerly.events.consume(request_id)
  #   rescue Fingerly::EventAlreadyConsumedError => e
  #     return "refuse" # another decision already used it, at e.consumed_at
  #   end
  class EventAlreadyConsumedError < APIError
    CODE = "event_already_consumed"

    # @return [String, nil] when the event was first consumed, as the API
    #   sent it (RFC 3339), or nil when the answer did not say
    attr_reader :consumed_at

    # @api private
    def initialize(consumed_at: nil, **)
      super(**)
      @consumed_at = consumed_at
    end
  end

  # Raised for any non-2xx answer to a DeviceCheck read or write.
  #
  # It is an {APIError}, so +rescue Fingerly::APIError+ still catches it; each
  # documented code has its own predicate.
  #
  #   begin
  #     bits = fingerly.device_check.query(request_id)
  #   rescue Fingerly::DeviceCheckError => e
  #     raise unless e.not_held? || e.spent? || e.apple_rejected?
  #
  #     bits = nil # no answer, not a verdict: decide without the bits
  #   end
  class DeviceCheckError < APIError
    NOT_HELD = "device_check_not_held"
    SPENT = "device_check_spent"
    BUSY = "device_check_busy"
    CREDENTIAL_UNAVAILABLE = "credential_unavailable"
    BITS_REQUIRED = "bits_required"
    APPLE_REJECTED = "apple_rejected"
    UNAVAILABLE = "device_check_unavailable"

    # @return [Integer, nil] Apple's HTTP status for +apple_rejected+, from
    #   the +apple_status+ entry of {#details}; nil for any other code
    attr_reader :apple_status

    # @api private
    def initialize(**)
      super
      @apple_status = parse_apple_status
    end

    # +404+: no token is held for that event. Decide without the bits.
    def not_held? = status == 404 && code == NOT_HELD

    # +409+: the token was already used, or this was a retry that is not the
    # request the token was first used for.
    def spent? = status == 409 && code == SPENT

    # +409+: another call is using the token right now.
    def busy? = status == 409 && code == BUSY

    # +409+: the project's Apple key is missing, refused, or has DeviceCheck
    # off. The token is kept: fix the key, then retry the same request.
    def credential_unavailable? = status == 409 && code == CREDENTIAL_UNAVAILABLE

    # +422+: a write named neither bit.
    def bits_required? = status == 422 && code == BITS_REQUIRED

    # +422+: Apple rejected the token, which is now used up. See
    # {#apple_status}.
    def apple_rejected? = status == 422 && code == APPLE_REJECTED

    # +503+: Apple or Fingerly's storage could not answer, after the retries
    # the client already made. The token is kept: retry the same request
    # within the hour.
    def unavailable? = status == 503 && code == UNAVAILABLE

    private

    def parse_apple_status
      return nil unless code == APPLE_REJECTED && details.is_a?(Array)

      entry = details.find { |item| item.is_a?(Hash) && item["field"] == "apple_status" }
      issue = entry && entry["issue"]
      issue.is_a?(String) && issue.match?(/\A\d{3}\z/) ? Integer(issue, 10) : nil
    end
  end

  # Raised when a request does not finish within its time limit.
  #
  # The deadline covers reading the response body, not only the headers.
  class TimeoutError < Error
    # @api private
    def initialize(message = "The Fingerly request timed out", connected: true)
      super(message)
      @connected = connected
    end

    # Whether a connection to the API was open when the time ran out. When it
    # was, the request may have reached the server, so sending it again could
    # do its work twice; when it was not, nothing was sent.
    #
    # @return [Boolean]
    def connected? = @connected
  end

  # Raised when the Fingerly API could not be reached at all.
  #
  # A DNS failure, a refused connection or a TLS error arrives here, and so
  # does a connection lost or a response cut short once the request was sent.
  class ConnectionError < Error
    # @api private
    def initialize(message = "Could not reach the Fingerly API", sent: false)
      super(message)
      @sent = sent
    end

    # Whether the whole request had been written when the connection failed.
    # When it had, the server may have acted on it, so sending it again could
    # do its work twice; when it had not, the server never saw all of it.
    #
    # @return [Boolean]
    def sent? = @sent
  end
end
