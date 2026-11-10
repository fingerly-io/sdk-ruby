# frozen_string_literal: true

require "test_helper"
require "openssl"

class WebhooksTest < Minitest::Test
  SECRET = "whsec_test"
  TIMESTAMP = "1800000000"
  SIGNED_AT = Time.at(1_800_000_000).utc
  PAYLOAD = '{"id":"evt_1","type":"identification.completed","data":{}}'

  def test_accepts_a_genuine_delivery
    assert verify(signature: sign(SECRET))
  end

  def test_accepts_either_signature_during_a_rotation
    header = "#{sign("whsec_previous")},#{sign(SECRET)}"

    assert verify(signature: header)
    assert verify(secret: "whsec_previous", signature: header)
  end

  def test_tolerates_whitespace_between_rotated_signatures
    assert verify(signature: "#{sign("whsec_previous")}, #{sign(SECRET)}")
  end

  def test_reads_at_most_thirty_two_signatures
    bogus = "sha256=#{"0" * 64}"

    assert verify(signature: (([bogus] * 31) + [sign(SECRET)]).join(","))
    refute verify(signature: (([bogus] * 32) + [sign(SECRET)]).join(","))
  end

  # The headers are the sender's to write. The README promises false, never an
  # exception, however the framework tags the strings.
  def test_a_header_invalid_in_its_encoding_is_false_rather_than_an_exception
    refute verify(timestamp: "\xFF\xFE", signature: sign(SECRET))
    refute verify(signature: "sha256=\xFF")
    refute verify(signature: "\xFF,\xFE ,")
    refute verify(signature: "abc".encode("UTF-16"))
    refute verify(timestamp: "123".encode("UTF-16"), signature: sign(SECRET))
  end

  def test_refuses_a_tampered_payload
    refute verify(payload: "#{PAYLOAD} ", signature: sign(SECRET))
  end

  def test_refuses_the_wrong_secret
    refute verify(secret: "whsec_other", signature: sign(SECRET))
  end

  def test_refuses_a_signature_over_a_different_timestamp
    # The timestamp is signed, so moving it invalidates the digest even though
    # the body is untouched.
    refute verify(timestamp: "1800000001", signature: sign(SECRET))
  end

  def test_refuses_a_delivery_outside_the_replay_window
    refute verify(signature: sign(SECRET), now: SIGNED_AT + 301)
    refute verify(signature: sign(SECRET), now: SIGNED_AT - 301)
  end

  def test_accepts_a_delivery_at_the_edge_of_the_window
    assert verify(signature: sign(SECRET), now: SIGNED_AT + 300)
    assert verify(signature: sign(SECRET), now: SIGNED_AT - 300)
  end

  def test_honours_an_explicit_tolerance
    assert verify(signature: sign(SECRET), tolerance: 3600, now: SIGNED_AT + 1800)
  end

  def test_refuses_a_malformed_signature_without_raising
    [
      nil, "", "sha256=", "sha256=zz", "nonsense",
      "sha1=#{"0" * 64}", "sha256=#{"0" * 63}", "sha256=#{"A" * 64}"
    ].each do |signature|
      refute verify(signature: signature), "accepted #{signature.inspect}"
    end
  end

  def test_refuses_an_uppercase_digest
    # Fingerly sends lowercase hex; anything else is not our signature.
    refute verify(signature: sign(SECRET).upcase)
  end

  def test_refuses_a_malformed_timestamp_without_raising
    [nil, "", "not-a-number", "-1800000000", "1800000000.5", " 1800000000"].each do |timestamp|
      refute verify(timestamp: timestamp, signature: sign(SECRET)), "accepted #{timestamp.inspect}"
    end
  end

  def test_refuses_missing_input_without_raising
    refute verify(secret: nil, signature: sign(SECRET))
    refute verify(secret: "", signature: sign(SECRET))
    refute verify(payload: nil, signature: sign(SECRET))
    refute verify(signature: nil)
  end

  def test_refuses_a_negative_tolerance
    refute verify(signature: sign(SECRET), tolerance: -1)
  end

  # A delivery body is bytes, not text. Concatenating a binary body onto a
  # UTF-8 timestamp would raise rather than simply fail to verify, so both are
  # forced to binary before signing.
  def test_verifies_a_body_that_is_not_valid_utf8
    binary = "\xff\xfe{}".b
    digest = OpenSSL::HMAC.hexdigest("SHA256", SECRET, "#{TIMESTAMP}.".b + binary)

    assert verify(payload: binary, signature: "sha256=#{digest}")
  end

  def test_parses_the_envelope
    delivery = Fingerly::Webhooks.parse(PAYLOAD)

    assert_equal "evt_1", delivery.id
    assert_equal "identification.completed", delivery.type
    assert_equal({}, delivery.data)
  end

  def test_refuses_to_parse_something_that_is_not_an_envelope
    assert_raises(Fingerly::Error) { Fingerly::Webhooks.parse("<html>") }
    assert_raises(Fingerly::Error) { Fingerly::Webhooks.parse("[1,2]") }
  end

  private

  def verify(secret: SECRET, payload: PAYLOAD, timestamp: TIMESTAMP, signature:,
             tolerance: Fingerly::Webhooks::DEFAULT_TOLERANCE, now: SIGNED_AT)
    Fingerly::Webhooks.verify(
      secret: secret, payload: payload, timestamp: timestamp,
      signature: signature, tolerance: tolerance, now: now
    )
  end

  # Signs the way Fingerly does, computed here rather than borrowed from the
  # SDK, so the test cannot agree with a mistake.
  def sign(secret)
    "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, "#{TIMESTAMP}.#{PAYLOAD}")}"
  end
end
