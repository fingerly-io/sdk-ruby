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

  # Only 503 is retried: a 500, 502 or 504 may have counted the batch.
  def test_any_other_status_is_dropped_and_logged_once_a_minute
    [400, 404, 413, 500, 502, 504].each do |code|
      @logger.lines.clear
      FakeAPI.run(status(code)) do |api|
        fingerly = sightings(api)
        fingerly.report(env)
        fingerly.flush
        api.handler = answering
        fingerly.flush

        assert_equal 1, api.requests.size, code.to_s
        assert_equal 1, @logger.lines.size, code.to_s
        assert_includes @logger.lines.first, code.to_s
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

  def test_a_retry_after_of_zero_or_already_past_still_stops_a_second
    ["0", "Thu, 01 Jan 2026 00:00:00 GMT"].each do |value|
      FakeAPI.run(status(429, "retry-after" => value)) do |api|
        fingerly = sightings(api)
        fingerly.report(env)
        fingerly.flush
        api.handler = answering
        @clock.advance(0.9)
        fingerly.flush

        assert_equal 1, api.requests.size, value
        @clock.advance(0.1)
        fingerly.flush

        assert_equal 2, api.requests.size, value
      end
    end
  end

  # A huge Retry-After must not stop reporting for the life of the process.
  def test_a_huge_retry_after_stops_a_day_at_most
    ["2147483647", "99999999999999999999", "Fri, 01 Jan 2100 00:00:00 GMT"].each do |value|
      FakeAPI.run(status(429, "retry-after" => value)) do |api|
        fingerly = sightings(api)
        fingerly.report(env)
        fingerly.flush
        api.handler = answering
        @clock.advance(86_400) # a day
        fingerly.flush

        assert_equal 2, api.requests.size, value
      end
    end
  end

  # An unreadable Retry-After, a negative one included, reads as none.
  def test_an_unreadable_retry_after_waits_a_minute
    ["-5", "soon"].each do |value|
      FakeAPI.run(status(429, "retry-after" => value)) do |api|
        fingerly = sightings(api)
        fingerly.report(env)
        fingerly.flush
        api.handler = answering
        @clock.advance(59)
        fingerly.flush

        assert_equal 1, api.requests.size, value
        @clock.advance(1)
        fingerly.flush

        assert_equal 2, api.requests.size, value
      end
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

  def test_a_refused_key_drops_the_batch_stops_for_a_minute_and_logs_once_a_minute
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
        assert_equal 1, @logger.lines.size
        @clock.advance(1)
        fingerly.flush

        # "a" was dropped; only "b" goes, a minute later, and is logged again.
        assert_equal [["a"], ["b"]], sent_agents(api)
        assert_equal 2, @logger.lines.size
        @logger.lines.each { |line| refute_includes line, SightingsHelpers::SECRET_KEY }
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
    FakeAPI.run(status(503)) do |api|
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

  # Once the whole request was written, the server may have counted it.
  def test_a_connection_lost_after_sending_drops_the_batch
    %i[closed cut_short].each do |ending|
      raw_api(ending) do |origin, served|
        fingerly = sightings(origin)
        fingerly.report(env)
        fingerly.flush

        assert_equal 1, served.size, ending.to_s
        assert_equal 0, fingerly.instance_variable_get(:@buffer).size, ending.to_s
        assert_nil fingerly.instance_variable_get(:@paused_until), ending.to_s
        assert_includes @logger.lines.last, "after it was sent", ending.to_s
      end
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

  # The bound counts the batch in flight, so a kept batch always fits back.
  def test_the_buffer_bound_counts_the_batch_in_flight
    release = Queue.new
    handler = lambda do |_req, res|
      release.pop
      res.status = 503
      res.body = ""
    end
    FakeAPI.run(handler) do |api|
      fingerly = sightings(api)
      buffer = fingerly.instance_variable_get(:@buffer)
      200.times { |i| fingerly.report(env(user_agent: "old-#{i}")) }

      assert(eventually? { api.requests.size == 1 })
      1000.times { |i| fingerly.report(env(user_agent: "new-#{i}")) }

      # 200 in flight and 800 pending fill it.
      assert_equal 200, fingerly.dropped_count
      release << true

      assert(eventually? { buffer.size == 1000 })
      assert_equal 200, fingerly.dropped_count
      assert_equal "old-0", buffer.instance_variable_get(:@items).values.first.fields[:user_agent]
    end
  end

  # A kept batch is as old as when it was first seen, so the two second rule
  # sends it as soon as the backoff ends, without an explicit flush.
  def test_a_kept_batch_keeps_its_first_seen_time
    FakeAPI.run(status(503)) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      @clock.advance(1.5)
      fingerly.flush
      api.handler = answering
      fingerly.report(env(user_agent: "newer"))
      @clock.advance(1)

      assert(eventually? { api.requests.size == 2 })
      sent = items_of(api.requests.last).map { |item| item["user_agent"] }

      assert_equal [GPTBOT, "newer"], sent
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

  # A server that reads each whole request, then closes the connection with
  # no answer (+:closed+) or after part of a body (+:cut_short+).
  def raw_api(ending)
    server = TCPServer.new("127.0.0.1", 0)
    served = Queue.new
    thread = Thread.new do
      loop do
        socket = server.accept
        head = +""
        head << socket.readpartial(4096) until head.include?("\r\n\r\n")
        length = head[/^content-length:\s*(\d+)/i, 1].to_i
        body = +(head.split("\r\n\r\n", 2)[1] || "")
        body << socket.readpartial(4096) while body.bytesize < length
        served << body
        if ending == :cut_short
          socket.write("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" \
                       "content-length: 100\r\n\r\n{\"rules_version\"")
        end
        socket.close
      end
    end
    yield "http://127.0.0.1:#{server.addr[1]}", served
  ensure
    thread&.kill
    server&.close
  end

  def sent_agents(api)
    api.requests.map { |request| items_of(request).map { |item| item["user_agent"] } }
  end
end
