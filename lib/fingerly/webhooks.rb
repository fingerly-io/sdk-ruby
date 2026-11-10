# frozen_string_literal: true

require "json"
require "openssl"

module Fingerly
  # Webhook signature verification.
  #
  # Stateless and module-level: verifying a delivery is one HMAC over bytes you
  # already have, so it needs no client.
  module Webhooks
    # How far a delivery's timestamp may be from now, in seconds, before it is
    # refused as a replay.
    DEFAULT_TOLERANCE = 300

    # A lowercase hex digest, exactly as Fingerly sends it. Anchored with \A
    # and \z because Ruby's ^ and $ match at every line boundary.
    SIGNATURE = /\Asha256=[a-f0-9]{64}\z/
    # Whole unsigned seconds, and nothing else.
    TIMESTAMP = /\A[0-9]+\z/

    PREFIX = "sha256="

    # Signatures read from one header. A rotation needs two; anything beyond
    # this is not from Fingerly, and is not worth comparing one by one.
    MAX_SIGNATURES = 32

    module_function

    # Reports whether a delivery came from Fingerly and is recent.
    #
    #   payload = request.body.read
    #   ok = Fingerly::Webhooks.verify(
    #     secret: ENV.fetch("FINGERLY_WEBHOOK_SECRET"),
    #     payload: payload,
    #     timestamp: request.get_header("HTTP_X_FINGERLY_TIMESTAMP"),
    #     signature: request.get_header("HTTP_X_FINGERLY_SIGNATURE"),
    #   )
    #
    # Verification proves authenticity and freshness. It does not deduplicate,
    # so persist processed {WebhookEvent#id} values as well.
    #
    # @param secret [String] the endpoint's signing secret
    # @param payload [String] the exact bytes received, before any JSON
    #   parsing: re-serialising them changes the digest
    # @param timestamp [String] the +x-fingerly-timestamp+ header
    # @param signature [String] the +x-fingerly-signature+ header, which
    #   carries several comma-separated signatures during a secret rotation.
    #   Any one of the first {MAX_SIGNATURES} matching is accepted.
    # @param tolerance [Numeric] the replay window in seconds
    # @param now [Time, nil] the instant to measure freshness against.
    #   Override it only in tests.
    # @return [Boolean] true when a signature matches and the timestamp is
    #   recent. Malformed or missing input returns false rather than raising.
    def verify(secret:, payload:, timestamp:, signature:,
               tolerance: DEFAULT_TOLERANCE, now: nil)
      return false unless secret.is_a?(String) && !secret.empty?
      return false unless payload.is_a?(String)
      return false unless timestamp.is_a?(String) && signature.is_a?(String)

      # Header values are whatever the sender wrote. As bytes, a value that is
      # not valid in its encoding simply fails to match, where as a string it
      # would raise from the regular expressions below.
      timestamp = timestamp.b
      signature = signature.b
      # Check freshness before spending an HMAC on an obvious replay.
      return false unless fresh?(timestamp, now, tolerance)

      expected = sign(secret, timestamp, payload)
      # The limit keeps a huge header from being split in full; whatever lies
      # past the last candidate is ignored rather than compared.
      candidates = signature.split(",", MAX_SIGNATURES + 1).first(MAX_SIGNATURES)
      candidates.any? { |candidate| matches?(candidate, expected) }
    end

    # Parses a delivery's envelope.
    #
    # Verify the bytes before calling this: parsing an unverified body is
    # trusting whoever sent it.
    #
    # @param payload [String] the raw delivery body
    # @return [WebhookEvent]
    # @raise [Error] if the body is not a Fingerly webhook envelope
    def parse(payload)
      parsed = JSON.parse(payload.to_s)
      raise Error, "Not a Fingerly webhook envelope" unless parsed.is_a?(Hash)

      WebhookEvent.new(parsed)
    rescue JSON::ParserError
      raise Error, "Not a Fingerly webhook envelope"
    end

    # Whether the signed time is within tolerance of now.
    # @api private
    def fresh?(timestamp, now, tolerance)
      return false unless TIMESTAMP.match?(timestamp)
      return false unless tolerance.is_a?(Numeric) && !tolerance.negative?

      moment = (now || Time.now).to_i
      (moment - Integer(timestamp, 10)).abs <= tolerance
    end

    # Computes the expected digest.
    #
    # Fingerly signs the timestamp, a literal dot, then the raw body bytes.
    # Both are forced to binary first: a body that is not valid UTF-8 would
    # otherwise raise on concatenation rather than simply fail to verify.
    #
    # @api private
    def sign(secret, timestamp, payload)
      signed = timestamp.b
      signed += "."
      signed += payload.b
      OpenSSL::HMAC.hexdigest("SHA256", secret, signed)
    end

    # Compares one candidate signature in constant time.
    # @api private
    def matches?(candidate, expected)
      value = candidate.strip
      return false unless SIGNATURE.match?(value)

      OpenSSL.fixed_length_secure_compare(value.delete_prefix(PREFIX), expected)
    end
  end
end
