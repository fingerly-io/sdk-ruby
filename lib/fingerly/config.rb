# frozen_string_literal: true

require "ipaddr"
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
    KEY = /\Afly_(pk|sk|px)_(production|staging|development)_[A-Za-z0-9_-]+\z/
    API_VERSION = /\Av[1-9][0-9]*\z/

    LABELS = { PUBLIC => "public", SECRET => "secret", PROXY => "proxy" }.freeze

    # The one Fingerly API origin.
    DEFAULT_ENDPOINT = "https://api.fingerly.io"

    # The environment a Fingerly key is scoped to.
    Scope = Struct.new(:environment)

    module_function

    # Parses a Fingerly key and asserts it is of the expected kind.
    #
    # @param key [String, nil] the raw key, such as +fly_sk_production_…+
    # @param expected [String] the kind the caller requires
    # @return [Scope] the environment the key is scoped to
    # @raise [ConfigurationError] if the key is malformed or of another kind,
    #   so a public, proxy or management key can never reach an API that would
    #   accept it
    def parse_key(key, expected)
      scope = scope_for(key, expected)
      return scope if scope

      raise ConfigurationError,
            "A valid Fingerly #{LABELS.fetch(expected)} key is required"
    end

    # The same, without raising.
    #
    # @return [Scope, nil] nil when the key is not of the expected kind
    def scope_for(key, expected)
      match = key.is_a?(String) ? KEY.match(key) : nil
      return nil unless match && match[1] == expected

      Scope.new(match[2])
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

    # Validates the path the dashboard issued for a proxy and drops trailing
    # slashes. It is matched exactly: the proxy answers that path and nothing
    # under it.
    def normalize_path(value)
      path = value.to_s.strip.sub(%r{/+\z}, "")
      segments = path.split("/", -1).drop(1)
      usable = path.match?(%r{\A(/[A-Za-z0-9._~-]+)+\z}) &&
               !segments.intersect?(%w[. ..])
      raise ConfigurationError, "path must be an absolute URL path such as /k7x2qm4a" unless usable

      path
    end

    # Whether a value is exactly one IPv4 or IPv6 address and nothing else: no
    # list, port, prefix length, zone, padding or whitespace.
    def ip_literal?(value)
      return false unless value.is_a?(String) && value.length <= 45
      return false unless value.match?(/\A[0-9A-Fa-f:.]+\z/)

      IPAddr.new(value)
      true
    rescue IPAddr::Error
      false
    end

    # Whether a value is printable ASCII, so it cannot inject a header of its
    # own.
    def header_safe?(value)
      value.is_a?(String) && value.match?(/\A[\x20-\x7e]*\z/)
    end
  end
end
