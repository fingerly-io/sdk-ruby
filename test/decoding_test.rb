# frozen_string_literal: true

require "test_helper"

# An answer that does not match the contract fails where it is read, with the
# SDK's own error, or reads as the absent value its type allows. It never
# hands the application a value of another type to fail on later.
class DecodingTest < Minitest::Test
  SECRET_KEY = "fly_sk_staging_abc123"
  AI = {
    "name" => "GPTBot", "provider" => "OpenAI", "purpose" => "training",
    "runtime" => "provider_cloud", "declared" => true,
    "verification" => { "method" => "ip_list", "result" => "fail" }
  }.freeze

  def test_an_ai_agent_always_has_its_verification
    ai = Fingerly::AiAgent.new(AI)

    assert_equal Fingerly::AiVerificationResult::FAIL, ai.verification.result
    assert_equal Fingerly::AiVerificationMethod::IP_LIST, ai.verification.method
  end

  def test_an_ai_agent_without_a_required_field_is_an_error_when_read
    broken = [
      AI.except("verification"), AI.merge("verification" => nil),
      AI.merge("verification" => "pass"), AI.merge("verification" => {}),
      AI.merge("verification" => { "method" => "ip_list", "result" => 1 }),
      AI.except("name"), AI.merge("provider" => nil), AI.merge("purpose" => 5),
      AI.merge("runtime" => []), AI.except("declared"), AI.merge("declared" => "yes")
    ]
    broken.each do |ai|
      error = assert_raises(Fingerly::Error, ai.inspect) { Fingerly::AiAgent.new(ai) }
      assert_instance_of Fingerly::Error, error
    end
  end

  def test_an_unknown_value_still_reads
    ai = Fingerly::AiAgent.new(
      AI.merge("purpose" => "dreaming",
               "verification" => { "method" => "quantum", "result" => "maybe" }, "new" => 1)
    )

    assert_equal "dreaming", ai.purpose
    assert_equal "maybe", ai.verification.result
  end

  def test_an_event_whose_ai_lacks_its_verification_fails_on_read
    [event("ai" => AI.except("verification")), event("ai" => "GPTBot")].each do |body|
      FakeAPI.run(FakeAPI.json(200, JSON.generate(body))) do |api|
        assert_raises(Fingerly::Error) { client(api).events.get("r1") }
        assert_raises(Fingerly::Error) { client(api).events.verify("r1", consume: false) }
      end
    end
  end

  # One unusable item is that request's answer, unknown; the others still
  # read. Only a body that is not an answer at all is an error.
  def test_a_sighting_whose_ai_lacks_its_verification_reads_as_unknown
    good = { "ttl" => 60, "visitor_kind" => "human" }
    payload = { "rules_version" => "r1",
                "items" => [{ "ttl" => 60, "visitor_kind" => "ai_bot",
                              "ai" => AI.except("verification") }, good, "GPTBot", nil] }
    report = Fingerly::AgentSightingsReport.new(payload)

    assert_equal 4, report.items.size
    assert_same Fingerly::AgentSightings::UNKNOWN, report.items[0]
    assert_equal "human", report.items[1].visitor_kind
    assert_same Fingerly::AgentSightings::UNKNOWN, report.items[2]
    assert_same Fingerly::AgentSightings::UNKNOWN, report.items[3]
    assert_raises(Fingerly::Error) do
      Fingerly::AgentSightingsReport.new("rules_version" => "r1", "items" => {})
    end
  end

  def test_fields_of_another_type_read_as_absent
    body = event(
      "visitor_id" => 42, "tag" => 7, "suspect_level" => ["high"], "suspect_score" => "90",
      "has_document" => "no", "document" => "x", "triggers" => { "vpn" => 1 }
    )
    FakeAPI.run(FakeAPI.json(200, JSON.generate(body))) do |api|
      event = client(api).events.get("r1")

      assert_nil event.visitor_id
      assert_nil event.tag
      assert_nil event.suspect_level
      assert_nil event.suspect_score
      refute_predicate event, :has_document?
      assert_nil event.document
      assert_empty event.triggers
      # verify reads the same fields; it answers rather than raising.
      result = client(api).events.verify("r1", consume: false, tag: "t")

      assert_equal Fingerly::VerifyReason::TAG_MISMATCH, result.reason
    end
  end

  def test_triggers_of_another_shape_are_skipped
    triggers = ["vpn", 5, nil, { "signal" => 1, "weight" => "9" },
                { "signal" => "vpn", "weight" => 10 }]
    body = event("triggers" => triggers)
    FakeAPI.run(FakeAPI.json(200, JSON.generate(body))) do |api|
      triggers = client(api).events.get("r1").triggers

      assert_equal [nil, "vpn"], triggers.map(&:signal)
      assert_equal [0, 10], triggers.map(&:weight)
    end
  end

  def test_a_page_of_another_shape_is_an_error
    ['{"rows":["row",5],"page":1}', '{"rows":{"a":1}}'].each do |body|
      FakeAPI.run(FakeAPI.json(200, body)) do |api|
        assert_raises(Fingerly::Error) { client(api).events.list }
      end
    end
    FakeAPI.run(FakeAPI.json(200, '{"rows":[],"page":"1","page_size":null}')) do |api|
      page = client(api).events.list

      assert_equal [0, 0], [page.page, page.page_size]
    end
  end

  def test_a_webhook_envelope_of_another_shape_reads_as_absent
    event = Fingerly::WebhookEvent.new("id" => 1, "type" => ["x"], "version" => "1",
                                       "data" => "payload")

    assert_nil event.id
    assert_nil event.type
    assert_nil event.version
    assert_equal({}, event.data)
  end

  private

  def event(fields)
    { "request_id" => "r1", "visitor_id" => "v1", "visitor_kind" => "ai_bot",
      "occurred_at" => Time.now.utc.iso8601, "suspect_score" => 10 }.merge(fields)
  end

  def client(api)
    Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: api.origin,
                         allow_insecure_loopback: true)
  end
end
