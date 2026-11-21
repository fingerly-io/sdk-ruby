# frozen_string_literal: true

require "sightings_helper"

# Section 6 of the agent sightings contract, one row at a time. In every case
# requests keep being served and lookup keeps answering.
class AgentSightingsFailuresTest < Minitest::Test
  include SightingsHelpers

  def test_ok_stores_the_answers_and_drops_the_sent_items
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      fingerly.flush
      fingerly.flush

      assert_equal 1, api.requests.size
      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
    end
  end

  def test_an_invalid_batch_is_dropped_and_logged_once_a_minute
    FakeAPI.run(status(422)) do |api|
      fingerly = sightings(api)
      fingerly.report(env(user_agent: "a"))
      fingerly.flush
      fingerly.report(env(user_agent: "b"))
      fingerly.flush

      assert_equal [["a"], ["b"]], sent_agents(api)
      assert_equal 1, @logger.lines.size
      @clock.advance(60)
      fingerly.report(env(user_agent: "c"))
      fingerly.flush

      assert_equal 2, @logger.lines.size
      assert_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env(user_agent: "a"))
    end
  end

  def test_any_other_refusal_is_dropped_like_an_invalid_batch
    [400, 404, 413].each do |code|
      FakeAPI.run(status(code)) do |api|
        fingerly = sightings(api)
        fingerly.report(env)
        fingerly.flush
        api.handler = answering
        fingerly.flush

        assert_equal 1, api.requests.size, code.to_s
      end
    end
  end

  def test_rate_limited_keeps_the_batch_until_retry_after
    FakeAPI.run(status(429, "retry-after" => "30")) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      fingerly.flush
      api.handler = answering
      # Counting goes on into the buffer meanwhile.
      fingerly.report(env)
      fingerly.flush
      @clock.advance(29)
      fingerly.flush

      assert_equal 1, api.requests.size
      @clock.advance(1)
      fingerly.flush

      assert_equal 2, api.requests.size
      assert_equal([2], items_of(api.requests.last).map { |item| item["count"] })
      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
    end
  end

  def test_rate_limited_without_retry_after_waits_a_minute
    FakeAPI.run(status(429)) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      fingerly.flush
      api.handler = answering
      @clock.advance(59)
      fingerly.flush

      assert_equal 1, api.requests.size
      @clock.advance(1)
      fingerly.flush

      assert_equal 2, api.requests.size
    end
  end

  def test_the_daily_allowance_waits_for_the_next_utc_day
    now = Time.now.utc
    left = Time.utc(now.year, now.month, now.day) + 86_400 - now
    skip "too close to midnight UTC" if left < 300

    FakeAPI.run(status(429, "fingerly-ratelimit-scope" => "daily")) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      fingerly.flush
      api.handler = answering
      @clock.advance(left - 120)
      fingerly.flush

      assert_equal 1, api.requests.size
      @clock.advance(240)
      fingerly.flush

      assert_equal 2, api.requests.size
    end
  end

  def test_a_refused_key_drops_the_batch_stops_for_a_minute_and_logs_once
    [401, 403].each do |code|
      @logger.lines.clear
      FakeAPI.run(status(code)) do |api|
        fingerly = sightings(api)
        fingerly.report(env(user_agent: "a"))
        fingerly.flush
        fingerly.report(env(user_agent: "b"))
        @clock.advance(59)
        fingerly.flush

        assert_equal 1, api.requests.size, code.to_s
        @clock.advance(1)
        fingerly.flush

        # "a" was dropped; only "b" goes, and the second refusal is not logged.
        assert_equal [["a"], ["b"]], sent_agents(api)
        assert_equal 1, @logger.lines.size
        refute_includes @logger.lines.first, SightingsHelpers::SECRET_KEY
      end
    end
  end

  def test_unavailable_keeps_the_batch_and_backs_off
    FakeAPI.run(status(503)) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      fingerly.flush
      fingerly.flush

      assert_equal 1, api.requests.size
      @clock.advance(1)
      fingerly.flush

      assert_equal 2, api.requests.size
      # Two seconds now.
      @clock.advance(1)
      fingerly.flush

      assert_equal 2, api.requests.size
      @clock.advance(1)
      api.handler = answering
      fingerly.flush

      assert_equal 3, api.requests.size
      assert_equal [[GPTBOT]], sent_agents(api).uniq
      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
    end
  end

  def test_the_backoff_stops_growing_at_a_minute_and_a_success_resets_it
    FakeAPI.run(status(500)) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      [1, 2, 4, 8, 16, 32, 60, 60].each do |wait|
        fingerly.flush
        @clock.advance(wait)
      end
      fingerly.flush
      sent = api.requests.size

      assert_equal 9, sent
      api.handler = answering
      @clock.advance(60)
      fingerly.flush
      api.handler = status(503)
      fingerly.report(env(user_agent: "again"))
      fingerly.flush
      @clock.advance(1)
      fingerly.flush

      assert_equal sent + 3, api.requests.size
    end
  end

  def test_a_transport_error_keeps_the_batch_and_backs_off
    closed = TCPServer.new("127.0.0.1", 0)
    port = closed.addr[1]
    closed.close
    fingerly = sightings("http://127.0.0.1:#{port}")
    fingerly.report(env)
    fingerly.flush
    buffer = fingerly.instance_variable_get(:@buffer)

    assert_equal 1, buffer.size
    assert_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
  end

  def test_a_timeout_after_sending_drops_the_batch
    handler = lambda do |req, res|
      sleep 6
      answering.call(req, res)
    end
    FakeAPI.run(handler) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      fingerly.flush

      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5.9
      api.handler = answering
      fingerly.flush

      assert_equal 1, api.requests.size
      assert_equal 0, fingerly.instance_variable_get(:@buffer).size
    end
  end

  def test_an_answer_of_the_wrong_length_is_dropped
    handler = lambda do |_req, res|
      res.status = 200
      res["content-type"] = "application/json"
      res.body = '{"rules_version":"r1","items":[]}'
    end
    FakeAPI.run(handler) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      fingerly.flush
      api.handler = answering
      fingerly.flush

      assert_equal 1, api.requests.size
      assert_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
    end
  end

  # A kept batch goes back in front of what arrived meanwhile; with the
  # buffer full, what no longer fits is counted as dropped.
  def test_a_kept_batch_that_no_longer_fits_is_counted
    release = Queue.new
    handler = lambda do |_req, res|
      release.pop
      res.status = 503
      res.body = ""
    end
    FakeAPI.run(handler) do |api|
      fingerly = sightings(api)
      200.times { |i| fingerly.report(env(user_agent: "old-#{i}")) }

      assert(eventually? { api.requests.size == 1 })
      # 1000 newer keys fill the buffer while the first 200 are in flight.
      1000.times { |i| fingerly.report(env(user_agent: "new-#{i}")) }
      release << true

      assert(eventually? { fingerly.dropped_count == 200 })
    end
  end

  def test_a_kept_batch_merges_with_newer_counts
    FakeAPI.run(status(503)) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      fingerly.flush
      2.times { fingerly.report(env) }
      @clock.advance(1)
      api.handler = answering
      fingerly.flush

      assert_equal([3], items_of(api.requests.last).map { |item| item["count"] })
    end
  end

  private

  def sent_agents(api)
    api.requests.map { |request| items_of(request).map { |item| item["user_agent"] } }
  end
end
