# frozen_string_literal: true

require "uri"

module Fingerly
  # Validation of caller-supplied configuration.
  #
  # Everything here runs before any network access, so a misconfigured client
  # fails while it is being built rather than mid-request or against the wrong
  # host.
  #
  # @api private
  module Config
    # Key kinds Fingerly issues: browser public, server secret, and proxy.
    PUBLIC = "pk"
    SECRET = "sk"
    PROXY = "px"

    # Anchored with \A and \z rather than ^ and $, which in Ruby match at every
    # line boundary. A key with a newline in it would otherwise pass.
    KEY = /\Afly_(pk|sk|px)_(eu|us)_(production|staging|development)_[A-Za-z0-9_-]+\z/
    API_VERSION = /\Av[1-9][0-9]*\z/

    LABELS = { PUBLIC => "public", SECRET => "secret", PROXY => "proxy" }.freeze

    # The region and environment a Fingerly key is scoped to.
    Scope = Struct.new(:region, :environment) do
      # @return [String] the Fingerly API origin serving this scope's region
      def origin
        "https://#{region}.api.fingerly.io"
      end
    end

    module_function

    # Parses a Fingerly key and asserts it is of the expected kind.
    #
    # @param key [String, nil] the raw key, such as +fly_sk_us_production_…+
    # @param expected [String] the kind the caller requires
    # @return [Scope] the region and environment the key is scoped to
    # @raise [ConfigurationError] if the key is malformed or of another kind,
    #   so a public, proxy or management key can never reach an API that would
    #   accept it
    def parse_key(key, expected)
      scope = scope_for(key, expected)
      return scope if scope

      raise ConfigurationError,
            "A valid regional Fingerly #{LABELS.fetch(expected)} key is required"
    end

    # The same, without raising.
    #
    # @return [Scope, nil] nil when the key is not of the expected kind
    def scope_for(key, expected)
      match = key.is_a?(String) ? KEY.match(key) : nil
      return nil unless match && match[1] == expected

      Scope.new(match[2], match[3])
    end

    # Validates a caller-supplied API origin.
    #
    # Credentials, queries and fragments are refused: they would be attached to
    # every authenticated request, and embedded credentials would leak on a
    # redirect.
    #
    # @return [String] the origin without trailing slashes
    # @raise [ConfigurationError] if the URL is malformed or carries any of those
    def normalize_endpoint(value)
      uri = begin
        URI.parse(value.to_s)
      rescue URI::InvalidURIError
        nil
      end
      usable = uri.is_a?(URI::HTTP) && !uri.host.to_s.empty? &&
               uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      unless usable
        raise ConfigurationError,
              "endpoint must be an HTTP(S) URL without credentials, query, or fragment"
      end

      value.to_s.sub(%r{/+\z}, "")
    end

    # Validates an API route version before it is spliced into a URL.
    #
    # @raise [ConfigurationError] if the version is not of that shape
    def normalize_api_version(version)
      return version if version.is_a?(String) && API_VERSION.match?(version)

      raise ConfigurationError, %(api_version must be a version such as "v1" or "v2")
    end

    # Validates a duration option, in seconds.
    #
    # @raise [ConfigurationError] if it is not a positive number
    def positive_seconds(value, name)
      return value if value.is_a?(Numeric) && value.positive?

      raise ConfigurationError, "#{name} must be a positive number of seconds"
    end

    # Validates a byte count option.
    #
    # @raise [ConfigurationError] if it is not a positive integer
    def positive_int(value, name)
      return value if value.is_a?(Integer) && value.positive?

      raise ConfigurationError, "#{name} must be a positive integer"
    end

    # Validates the local mount path and drops trailing slashes.
    def normalize_prefix(value)
      prefix = value.to_s.sub(%r{/+\z}, "")
      unless prefix.start_with?("/") && !prefix.match?(/[?#]/)
        raise ConfigurationError, "prefix must be an absolute URL path"
      end

      prefix
    end

    # Whether a value is printable ASCII, so it cannot inject a header of its
    # own.
    def header_safe?(value)
      value.is_a?(String) && value.match?(/\A[\x20-\x7e]*\z/)
    end
  end
end
