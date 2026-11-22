# frozen_string_literal: true

require "test_helper"

class AgentsTest < Minitest::Test
  SECRET_KEY = "fly_sk_production_agents"
  ANSWER = '{"rules_version":"r1","items":[{"ttl":60,"visitor_kind":"human"}]}'

  def test_posts_the_items_to_the_sightings_route_with_the_secret_key
    FakeAPI.run(FakeAPI.json(200, ANSWER)) do |api|
      client(api).agents.report_sightings([input(count: 3, host: "example.com")])
      request = api.requests.first

      assert_equal "POST", request.request_method
      assert_equal "/api/v1/agents/sightings", request.raw_uri
      assert_equal SECRET_KEY, request.header("x-api-key")
      assert_equal "application/json", request.header("content-type")
      assert_equal(
        { "items" => [{ "user_agent" => "GPTBot/1.4", "client_ip" => "203.0.113.7",
                        "host" => "example.com", "method" => "GET", "count" => 3 }] },
        JSON.parse(request.body)
      )
    end
  end

  def test_reads_the_answer
    FakeAPI.run(FakeAPI.json(200, ANSWER)) do |api|
      report = client(api).agents.report_sightings([input])

      assert_equal "r1", report.rules_version
      assert_equal 60, report.items.first.ttl
      assert_equal Fingerly::VisitorKind::HUMAN, report.items.first.visitor_kind
      assert_nil report.items.first.ai
    end
  end

  def test_refuses_no_items_too_many_or_the_wrong_type_before_sending
    FakeAPI.run(FakeAPI.json(200, ANSWER)) do |api|
      [[], [input] * 201, [{ "user_agent" => "x" }], nil].each do |items|
        assert_raises(Fingerly::ConfigurationError) do
          client(api).agents.report_sightings(items)
        end
      end

      assert_empty api.requests
    end
  end

  def test_a_header_that_is_not_utf8_is_still_sent_as_json
    FakeAPI.run(FakeAPI.json(200, ANSWER)) do |api|
      client(api).agents.report_sightings([input(user_agent: "bot\xFF/1".b)])

      assert_equal "bot�/1", JSON.parse(api.requests.first.body)["items"][0]["user_agent"]
    end
  end

  def test_a_rate_limited_answer_carries_retry_after_and_its_scope
    handler = lambda do |_req, res|
      res.status = 429
      res["retry-after"] = "120"
      res["fingerly-ratelimit-scope"] = "daily"
      res["content-type"] = "application/json"
      res.body = '{"error":{"code":"rate_limited"}}'
    end
    FakeAPI.run(handler) do |api|
      error = assert_raises(Fingerly::APIError) do
        client(api).agents.report_sightings([input])
      end

      assert_equal 429, error.status
      assert_equal 120, error.retry_after
      assert_equal Fingerly::APIError::RATE_LIMIT_SCOPE_DAILY, error.rate_limit_scope
    end
  end

  def test_maps_a_refused_key_and_an_invalid_batch
    [[401, "unauthorized"], [403, "forbidden"], [422, "invalid_request"]].each do |status, code|
      FakeAPI.run(FakeAPI.json(status, "{\"error\":{\"code\":\"#{code}\"}}")) do |api|
        error = assert_raises(Fingerly::APIError) do
          client(api).agents.report_sightings([input])
        end

        assert_equal status, error.status
        assert_equal code, error.code
        assert_nil error.rate_limit_scope
      end
    end
  end

  def test_a_body_of_another_shape_is_an_error
    ['{"items":[]}', '{"rules_version":"r1","items":{}}', "[]"].each do |body|
      FakeAPI.run(FakeAPI.json(200, body)) do |api|
        assert_raises(Fingerly::Error) { client(api).agents.report_sightings([input]) }
      end
    end
  end

  def test_an_item_of_another_shape_is_unknown
    FakeAPI.run(FakeAPI.json(200, '{"rules_version":"r1","items":[1]}')) do |api|
      report = client(api).agents.report_sightings([input])

      assert_equal [Fingerly::AgentSightings::UNKNOWN], report.items
    end
  end

  def test_a_timeout_after_connecting_says_the_request_may_have_arrived
    handler = lambda do |_req, res|
      sleep 1.5
      res.status = 200
      res.body = ANSWER
    end
    FakeAPI.run(handler) do |api|
      error = assert_raises(Fingerly::TimeoutError) do
        client(api, timeout: 0.3).agents.report_sightings([input])
      end

      assert_predicate error, :connected?
    end
  end

  def test_a_timeout_while_connecting_says_nothing_was_sent
    stall = lambda do |http|
      # Stands in for a SYN nobody answers.
      def http.connect = sleep(5)
    end
    fingerly = Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: "http://127.0.0.1:9",
                                    allow_insecure_loopback: true, timeout: 0.3,
                                    configure_http: stall)
    error = assert_raises(Fingerly::TimeoutError) { fingerly.agents.report_sightings([input]) }

    refute_predicate error, :connected?
  end

  def test_the_input_never_prints_the_visitors_request
    shown = input(signature: "sig1=:abc:").inspect

    refute_includes shown, "GPTBot"
    refute_includes shown, "203.0.113.7"
    refute_includes shown, "abc"
  end

  private

  def input(user_agent: "GPTBot/1.4", count: nil, host: nil, signature: nil)
    Fingerly::AgentSightingInput.new(user_agent: user_agent, client_ip: "203.0.113.7",
                                     host: host, request_method: "GET", signature: signature,
                                     count: count)
  end

  def client(api, timeout: 10)
    Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: api.origin,
                         allow_insecure_loopback: true, timeout: timeout)
  end
end
