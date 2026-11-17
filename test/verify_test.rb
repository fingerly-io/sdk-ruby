# frozen_string_literal: true

require "test_helper"

# events.consume marks an event used once; events.verify reads it, checks it
# in a fixed order, and consumes it only when every check passed.
class VerifyTest < Minitest::Test
  SECRET_KEY = "fly_sk_staging_abc123"
  REQUEST_ID = "01a1e665-198c-760c-abf9-3666cb1c8e85"
  CONSUMED_AT = "2026-11-17T10:00:00Z"
  CONSUMED = JSON.generate("request_id" => REQUEST_ID, "consumed_at" => CONSUMED_AT,
                           "first" => true)
  LITERAL_409 = JSON.generate("code" => "event_already_consumed", "consumed_at" => CONSUMED_AT)
  ENVELOPE_409 = JSON.generate(
    "error" => {
      "code" => "event_already_consumed", "message" => "already consumed", "status" => 409,
      "details" => [{ "field" => "consumed_at", "issue" => CONSUMED_AT, "location" => "body" }]
    }
  )

  # consume

  def test_consume_posts_with_no_body_and_reads_the_result
    FakeAPI.run(FakeAPI.json(200, CONSUMED)) do |api|
      consumed = client(api).events.consume(REQUEST_ID)

      assert_equal REQUEST_ID, consumed.request_id
      assert_equal CONSUMED_AT, consumed.consumed_at
      assert_predicate consumed, :first?

      request = api.requests.first

      assert_equal 1, api.requests.size
      assert_equal "POST", request.request_method
      assert_equal "/api/v1/events/#{REQUEST_ID}/consume", request.raw_uri
      assert_equal SECRET_KEY, request.header("x-api-key")
      assert_equal "", request.body
    end
  end

  def test_consume_escapes_the_request_id
    FakeAPI.run(FakeAPI.json(200, CONSUMED)) do |api|
      client(api).events.consume("a/../b c")

      assert_equal "/api/v1/events/a%2F..%2Fb%20c/consume", api.requests.first.raw_uri
    end
  end

  def test_consume_refuses_a_bad_request_id_before_sending
    FakeAPI.run(FakeAPI.json(200, CONSUMED)) do |api|
      ["", ".", ".."].each do |bad|
        assert_raises(Fingerly::ConfigurationError) { client(api).events.consume(bad) }
      end
      assert_empty api.requests
    end
  end

  def test_already_consumed_in_either_shape_raises_the_typed_error
    [LITERAL_409, ENVELOPE_409].each do |body|
      FakeAPI.run(FakeAPI.json(409, body)) do |api|
        error = assert_raises(Fingerly::EventAlreadyConsumedError) { client(api).events.consume(REQUEST_ID) }

        assert_kind_of Fingerly::APIError, error
        assert_equal 409, error.status
        assert_equal "event_already_consumed", error.code
        assert_equal CONSUMED_AT, error.consumed_at
        assert_predicate error, :event_already_consumed?
        assert_equal 1, api.requests.size, "a consume must not be retried"
      end
    end
  end

  def test_already_consumed_reads_consumed_at_inside_the_envelope
    body = JSON.generate("error" => { "code" => "event_already_consumed",
                                      "consumed_at" => CONSUMED_AT })
    FakeAPI.run(FakeAPI.json(409, body)) do |api|
      error = assert_raises(Fingerly::EventAlreadyConsumedError) { client(api).events.consume(REQUEST_ID) }

      assert_equal CONSUMED_AT, error.consumed_at
    end
  end

  def test_already_consumed_without_a_time_has_nil_consumed_at
    FakeAPI.run(FakeAPI.json(409, error("event_already_consumed"))) do |api|
      error = assert_raises(Fingerly::EventAlreadyConsumedError) { client(api).events.consume(REQUEST_ID) }

      assert_nil error.consumed_at
    end
  end

  def test_consume_of_an_unknown_event_raises_the_plain_api_error
    FakeAPI.run(FakeAPI.json(404, error("event_not_found"))) do |api|
      error = assert_raises(Fingerly::APIError) { client(api).events.consume(REQUEST_ID) }

      refute_kind_of Fingerly::EventAlreadyConsumedError, error
      assert_predicate error, :event_not_found?
    end
  end

  def test_consume_errors_never_echo_the_key
    body = JSON.generate("code" => "event_already_consumed", "consumed_at" => SECRET_KEY)
    FakeAPI.run(FakeAPI.json(409, body)) do |api|
      error = assert_raises(Fingerly::EventAlreadyConsumedError) { client(api).events.consume(REQUEST_ID) }

      refute_includes error.consumed_at, SECRET_KEY
      refute_includes error.message, SECRET_KEY
    end
  end

  # verify

  def test_ok_reads_then_consumes_once
    FakeAPI.run(routes(event)) do |api|
      result = client(api).events.verify(REQUEST_ID)

      assert_predicate result, :ok?
      assert_equal "", result.reason
      assert_equal REQUEST_ID, result.event.request_id
      expected = [["GET", "/api/v1/events/#{REQUEST_ID}"],
                  ["POST", "/api/v1/events/#{REQUEST_ID}/consume"]]

      assert_equal(expected, api.requests.map { |r| [r.request_method, r.raw_uri] })
    end
  end

  def test_not_found_has_no_event
    FakeAPI.run(routes(nil)) do |api|
      result = client(api).events.verify(REQUEST_ID)

      refute_predicate result, :ok?
      assert_equal "not_found", result.reason
      assert_nil result.event
      assert_equal 0, consumes(api)
    end
  end

  def test_too_old
    FakeAPI.run(routes(event(age: 4000))) do |api|
      result = client(api).events.verify(REQUEST_ID)

      assert_equal "too_old", result.reason
      refute_nil result.event
      assert_equal 0, consumes(api)
    end
  end

  def test_an_unreadable_or_missing_time_is_too_old
    ["yesterday", "2026-11-17", nil, 17].each do |value|
      FakeAPI.run(routes(event.merge("occurred_at" => value))) do |api|
        result = client(api).events.verify(REQUEST_ID)

        assert_equal "too_old", result.reason, "occurred_at #{value.inspect}"
        assert_nil result.event.occurred_at
        assert_equal 0, consumes(api)
      end
    end
  end

  def test_a_future_time_passes_the_age_check
    FakeAPI.run(routes(event(age: -3600))) do |api|
      assert_predicate client(api).events.verify(REQUEST_ID), :ok?
    end
  end

  def test_the_default_max_age_is_300_seconds
    assert_equal 300, Fingerly::Events::DEFAULT_MAX_AGE_SECONDS
    FakeAPI.run(routes(event(age: 200))) do |api|
      assert_predicate client(api).events.verify(REQUEST_ID), :ok?
    end
    FakeAPI.run(routes(event(age: 400))) do |api|
      assert_equal "too_old", client(api).events.verify(REQUEST_ID).reason
    end
    FakeAPI.run(routes(event(age: 400))) do |api|
      assert_predicate client(api).events.verify(REQUEST_ID, max_age_seconds: 600), :ok?
    end
  end

  def test_tag_mismatch
    [event.merge("tag" => "login"), event.merge("tag" => nil),
     event.except("tag")].each do |payload|
      FakeAPI.run(routes(payload)) do |api|
        result = client(api).events.verify(REQUEST_ID, tag: "checkout")

        assert_equal "tag_mismatch", result.reason
        assert_equal 0, consumes(api)
      end
    end
  end

  def test_a_matching_tag_passes_and_no_tag_skips_the_check
    FakeAPI.run(routes(event)) do |api|
      assert_predicate client(api).events.verify(REQUEST_ID, tag: "checkout"), :ok?
    end
    FakeAPI.run(routes(event.except("tag"))) do |api|
      assert_predicate client(api).events.verify(REQUEST_ID), :ok?
    end
  end

  def test_unidentifiable
    [event.merge("visitor_id" => ""), event.except("visitor_id")].each do |payload|
      FakeAPI.run(routes(payload)) do |api|
        assert_equal "unidentifiable", client(api).events.verify(REQUEST_ID).reason
        assert_equal 0, consumes(api)
      end
    end
  end

  def test_unscored
    [event.merge("suspect_score" => nil), event.except("suspect_score")].each do |payload|
      FakeAPI.run(routes(payload)) do |api|
        assert_equal "unscored", client(api).events.verify(REQUEST_ID).reason
        assert_equal 0, consumes(api)
      end
    end
  end

  def test_the_score_itself_is_not_judged
    payload = event.merge("suspect_score" => 100, "suspect_level" => "high",
                          "triggers" => [{ "signal" => "tampering", "weight" => 100 }])

    FakeAPI.run(routes(payload)) do |api|
      assert_predicate client(api).events.verify(REQUEST_ID), :ok?
    end
  end

  def test_already_consumed_keeps_the_event
    [LITERAL_409, ENVELOPE_409].each do |body|
      FakeAPI.run(routes(event, consume: [409, body])) do |api|
        result = client(api).events.verify(REQUEST_ID)

        assert_equal "already_consumed", result.reason
        assert_equal REQUEST_ID, result.event.request_id
        assert_equal 1, consumes(api)
      end
    end
  end

  def test_not_found_on_consume_has_no_event
    FakeAPI.run(routes(event, consume: [404, error("event_not_found")])) do |api|
      result = client(api).events.verify(REQUEST_ID)

      assert_equal "not_found", result.reason
      assert_nil result.event
    end
  end

  def test_other_consume_failures_are_raised
    FakeAPI.run(routes(event, consume: [500, error("internal")])) do |api|
      error = assert_raises(Fingerly::APIError) { client(api).events.verify(REQUEST_ID) }

      assert_equal 500, error.status
    end
  end

  def test_consume_false_never_posts
    FakeAPI.run(routes(event)) do |api|
      result = client(api).events.verify(REQUEST_ID, consume: false)

      assert_predicate result, :ok?
      assert_equal 0, consumes(api)
      assert_equal 1, api.requests.size
    end
  end

  def test_the_first_failing_check_wins
    stale_untagged_unidentifiable = event(age: 4000).merge("tag" => "", "visitor_id" => "",
                                                           "suspect_score" => nil)
    untagged_unidentifiable = event.merge("tag" => "", "visitor_id" => "", "suspect_score" => nil)
    unidentifiable_unscored = event.merge("visitor_id" => "", "suspect_score" => nil)
    [
      [stale_untagged_unidentifiable, "too_old"],
      [untagged_unidentifiable, "tag_mismatch"],
      [unidentifiable_unscored, "unidentifiable"]
    ].each do |payload, reason|
      FakeAPI.run(routes(payload)) do |api|
        assert_equal reason, client(api).events.verify(REQUEST_ID, tag: "checkout").reason
        assert_equal 0, consumes(api)
      end
    end
  end

  def test_read_failures_other_than_not_found_are_raised
    [[404, "event_pending"], [401, "unauthorized"], [429, "rate_limited"],
     [503, "unavailable"]].each do |status, code|
      FakeAPI.run(FakeAPI.json(status, error(code))) do |api|
        error = assert_raises(Fingerly::APIError) { client(api).events.verify(REQUEST_ID) }

        assert_equal code, error.code
        assert_equal 0, consumes(api)
      end
    end
  end

  def test_invalid_options_are_refused_before_sending
    FakeAPI.run(routes(event)) do |api|
      events = client(api).events

      [0, -1, 1.5, "300", nil, true].each do |age|
        assert_raises(Fingerly::ConfigurationError) { events.verify(REQUEST_ID, max_age_seconds: age) }
      end
      ["", 1, :checkout].each do |tag|
        assert_raises(Fingerly::ConfigurationError) { events.verify(REQUEST_ID, tag: tag) }
      end
      [nil, "yes", 1].each do |consume|
        assert_raises(Fingerly::ConfigurationError) { events.verify(REQUEST_ID, consume: consume) }
      end
      ["", ".", ".."].each do |bad|
        assert_raises(Fingerly::ConfigurationError) { events.verify(bad) }
      end
      assert_empty api.requests
    end
  end

  def test_the_reasons_are_the_wire_strings
    assert_equal %w[not_found too_old tag_mismatch unidentifiable unscored already_consumed],
                 Fingerly::EventVerification::REASONS
  end

  private

  def event(age: 10)
    {
      "request_id" => REQUEST_ID,
      "visitor_id" => "v_123",
      "tag" => "checkout",
      "occurred_at" => (Time.now.utc - age).iso8601(3),
      "suspect_score" => 12,
      "suspect_level" => "low",
      "triggers" => []
    }
  end

  # Answers the event read with +payload+ (404 event_not_found when nil) and
  # the consume with +consume+ as [status, body].
  def routes(payload, consume: [200, CONSUMED])
    lambda do |req, res|
      res["content-type"] = "application/json"
      if req.request_method == "POST"
        res.status, res.body = consume
      elsif payload
        res.status = 200
        res.body = JSON.generate(payload)
      else
        res.status = 404
        res.body = error("event_not_found")
      end
    end
  end

  def consumes(api)
    api.requests.count { |r| r.request_method == "POST" && r.raw_uri.end_with?("/consume") }
  end

  def error(code)
    JSON.generate("error" => { "code" => code, "message" => code, "status" => 0 })
  end

  def client(api)
    Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: api.origin,
                         allow_insecure_loopback: true)
  end
end
