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
  #     return "refuse" if e.status == 404
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

    # @api private
    def initialize(status:, code: nil, details: nil, request_id: nil)
      @status = status
      @code = code
      @details = details
      @request_id = request_id
      described = "Fingerly API returned HTTP #{status}"
      super(code ? "#{described} (#{code})" : described)
    end

    # Whether this is a read for an event that does not exist.
    #
    # One is readable as soon as identification answers, so this means a
    # request id that was never issued rather than one that has not landed.
    #
    # @return [Boolean]
    def event_not_found?
      status == 404 && code == "event_not_found"
    end
  end

  # Raised when a request does not finish within its time limit.
  #
  # The deadline covers reading the response body, not only the headers.
  class TimeoutError < Error; end

  # Raised when the Fingerly API could not be reached at all.
  #
  # A DNS failure, a refused connection or a TLS error arrives here.
  class ConnectionError < Error; end
end
