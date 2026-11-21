# frozen_string_literal: true

require "test_helper"

# The named constants are the server's own wire strings. Each expected list
# below is copied from the server's definitions, so a typo, a dropped value
# or an invented one fails here rather than in a customer's comparison.
class EnumsTest < Minitest::Test
  EXPECTED = {
    Fingerly::Signal => %w[
      high_activity tampering device_farm developer_tools geo_mismatch device_inconsistent
      tor proxy residential_proxy residential_proxy_low_confidence
      residential_proxy_medium_confidence residential_proxy_high_confidence
      vpn_public vpn_relay vpn_mobile vpn_os_mismatch
      vpn_low_confidence vpn_medium_confidence vpn_high_confidence
      ip_blocklist_email_spam ip_blocklist_attack_source ip_abuser datacenter_ip bogon_ip
      anycast_ip
      incognito bad_bot ai_spoofed automation fetch_metadata_missing web_ticket_missing
      web_ticket_invalid antidetect_browser virtual_machine fingerprint_suppressed
      identity_obfuscated privacy_settings embedded_web_view remote_control
      emulator root_apps app_cloner jailbreak simulator frida mitm_attack active_call
      attestation_missing attestation_downgrade repeated_reinstall device_activity_high
      device_activity_very_high play_device_integrity_failed play_app_unrecognized
      attestation_failed report_incomplete probe_errors custom_root_ca secondary_user_profile
      datacenter_proxy vpn ip_blocklist ip_reputation network_anomaly location_spoofing
      ios_simulator android_emulator jailbroken_device rooted_device cloned_app
      frida_detected browser_tampering bot incognito_mode
    ],
    Fingerly::SuspectLevel => %w[low medium high],
    Fingerly::Confidence => %w[low medium high],
    Fingerly::AttestationState => %w[attested not_attested failed],
    Fingerly::AttestationStatus => %w[verified indeterminate invalid absent unconfigured],
    Fingerly::AttestSkippedReason => %w[
      not_offered unsupported challenge_unavailable key_error timeout backoff
      install_unavailable
    ],
    Fingerly::VerifyReason => [""] + %w[
      not_found too_old tag_mismatch unidentifiable unscored already_consumed
    ],
    Fingerly::WebhookEventType => %w[
      identification.completed identification.refused visitor.suspect
      billing.status_changed usage.daily_settled webhook.test
    ],
    Fingerly::WebhookEnvironment => %w[live test],
    Fingerly::EventState => %w[pending enriched unavailable],
    Fingerly::Environment => %w[production staging development],
    Fingerly::Platform => %w[web android ios],
    Fingerly::AnonymityNetwork => %w[tor relay vpn proxy hosting],
    Fingerly::DeviceKind => %w[desktop mobile tablet server],
    Fingerly::VisitorKind => %w[human ai_bot automation search_crawler],
    Fingerly::AiPurpose => %w[training search user_fetch agent],
    Fingerly::AiRuntime => %w[provider_cloud hosted_browser user_device],
    Fingerly::AiVerificationMethod => %w[signature ip_list reverse_dns none],
    Fingerly::AiVerificationResult => %w[pass fail not_attempted]
  }.freeze

  def test_every_module_lists_exactly_the_server_values_in_order
    EXPECTED.each do |mod, values|
      assert_equal values, mod::ALL, "#{mod}::ALL"
    end
  end

  def test_all_holds_every_constant_once
    EXPECTED.each_key do |mod|
      declared = (mod.constants - [:ALL]).map { |name| mod.const_get(name) }

      assert_equal declared.sort, mod::ALL.sort, "#{mod}::ALL misses a constant"
      assert_equal mod::ALL.uniq, mod::ALL, "#{mod}::ALL repeats a value"
    end
  end

  # The name is the value, upper-cased with dots as underscores, so a reader
  # can write the constant for any wire string they see.
  def test_each_name_spells_its_value
    EXPECTED.each_key do |mod|
      (mod.constants - %i[ALL OK]).each do |name|
        assert_equal name.to_s, mod.const_get(name).upcase.tr(".", "_"), "#{mod}::#{name}"
      end
    end
  end

  def test_values_and_lists_are_frozen_strings
    EXPECTED.each_key do |mod|
      assert_predicate mod::ALL, :frozen?, "#{mod}::ALL"
      mod::ALL.each do |value|
        assert_instance_of String, value
        assert_predicate value, :frozen?, "#{mod} #{value}"
      end
    end
  end

  def test_constants_compare_equal_to_decoded_fields
    trigger = { "signal" => "fingerprint_suppressed", "weight" => 6, "confidence" => "high" }
    event = Fingerly::Event.new(
      { "request_id" => "r", "occurred_at" => "2026-01-02T03:04:05Z", "state" => "enriched",
        "suspect_score" => 80, "suspect_level" => "high", "platform" => "web",
        "triggers" => [trigger] }
    )

    assert_equal Fingerly::SuspectLevel::HIGH, event.suspect_level
    assert_equal Fingerly::EventState::ENRICHED, event.state
    assert_equal Fingerly::Platform::WEB, event.platform
    assert_equal Fingerly::Signal::FINGERPRINT_SUPPRESSED, event.triggers.first.signal
    assert_equal Fingerly::Confidence::HIGH, event.triggers.first.confidence
  end

  def test_an_unknown_value_arrives_unchanged
    trigger = Fingerly::EventTrigger.new("signal" => "a_signal_added_later", "weight" => 1)

    assert_equal "a_signal_added_later", trigger.signal
    refute_includes Fingerly::Signal::ALL, trigger.signal
  end

  def test_the_model_constants_are_the_same_strings
    assert_equal "", Fingerly::VerifyReason::OK
    assert_equal Fingerly::VerifyReason::ALL - [""], Fingerly::EventVerification::REASONS
    assert_same Fingerly::VerifyReason::TOO_OLD, Fingerly::EventVerification::TOO_OLD
    Fingerly::EventTrigger.constants.grep(/\ASIGNAL_/).each do |name|
      assert_same Fingerly::Signal.const_get(name.to_s.delete_prefix("SIGNAL_")),
                  Fingerly::EventTrigger.const_get(name)
    end
    assert_empty Fingerly::EventTrigger::V3_SIGNALS - Fingerly::Signal::ALL
  end
end
