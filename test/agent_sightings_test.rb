# frozen_string_literal: true

require "sightings_helper"

class AgentSightingsTest < Minitest::Test
  include SightingsHelpers

  def test_unknown_is_a_named_answer_that_fails_open
    unknown = Fingerly::AgentSightings::UNKNOWN

    assert_equal "", unknown.visitor_kind
    refute_includes Fingerly::VisitorKind::ALL, unknown.visitor_kind
    assert_equal 0, unknown.ttl
    assert_nil unknown.agent
    assert_nil unknown.ai
  end

  def test_answers_unknown_before_the_server_said_anything
    FakeAPI.run(answering) do |api|
      assert_same Fingerly::AgentSightings::UNKNOWN, sightings(api).lookup(env)
    end
  end

  def test_answers_from_memory_once_the_server_answered
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      fingerly.flush
      answer = fingerly.lookup(env)

      assert_equal Fingerly::VisitorKind::AI_BOT, answer.visitor_kind
      assert_equal "GPTBot", answer.agent
      # The same request through a Rack::Request-like object.
      assert_same answer, fingerly.lookup(Struct.new(:env).new(env))
    end
  end

  # The key is the canonical address, so the two spellings share one answer.
  def test_an_ipv4_mapped_address_shares_the_ipv4_answer
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      fingerly.report(env(ip: "::ffff:20.171.206.9"))
      fingerly.flush

      assert_equal "20.171.206.9", items_of(api.requests.first).first["client_ip"]
      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env(ip: "20.171.206.9"))
      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env(ip: "::FFFF:20.171.206.9"))
    end
  end

  def test_sends_only_the_fields_of_the_contract
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      fingerly.report(signed_env(accept_language: "tr"))
      fingerly.flush
      body = api.requests.first.body

      assert_equal(
        [{ "user_agent" => GPTBOT, "client_ip" => "203.0.113.7", "host" => "example.com",
           "method" => "GET", "signature" => "sig1=:abc:",
           "signature_input" => 'sig1=("@authority")',
           "signature_agent" => '"https://chatgpt.com"', "count" => 1 }],
        items_of(api.requests.first)
      )
      %w[/page q=secret session Bearer tr].each { |secret| refute_includes body, secret }
    end
  end

  def test_an_absent_user_agent_is_reported_as_empty
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      fingerly.report(env(user_agent: nil))
      fingerly.flush

      assert_equal "", items_of(api.requests.first).first["user_agent"]
    end
  end

  def test_the_lru_keeps_at_most_its_capacity_and_drops_the_least_recent
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api, capacity: 2)
      fingerly.report(env(user_agent: "a"))
      fingerly.report(env(user_agent: "b"))
      fingerly.flush
      # "a" is now the most recently used.
      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env(user_agent: "a"))
      fingerly.report(env(user_agent: "c"))
      fingerly.flush

      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env(user_agent: "a"))
      assert_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env(user_agent: "b"))
      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env(user_agent: "c"))
    end
  end

  def test_capacity_is_bounded
    FakeAPI.run(answering) do |api|
      [0, -1, 1.5, nil].each do |capacity|
        assert_raises(Fingerly::ConfigurationError) { sightings(api, capacity: capacity) }
      end

      assert_equal 65_536, sightings(api, capacity: 65_536).capacity
      # Above the hard maximum is read as the maximum.
      assert_equal 65_536, sightings(api, capacity: 1_000_000).capacity
      assert_equal 4096, sightings(api).capacity
    end
  end

  def test_an_answer_expires_after_its_ttl
    FakeAPI.run(answering(ttl: 10)) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      fingerly.flush
      @clock.advance(9.9)

      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
      @clock.advance(0.1)

      assert_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
    end
  end

  def test_an_answer_is_kept_a_day_at_most
    FakeAPI.run(answering(ttl: 30 * 86_400)) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      fingerly.flush
      @clock.advance(86_399)

      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
      @clock.advance(1)

      assert_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
    end
  end

  def test_a_ttl_of_zero_is_never_cached
    FakeAPI.run(answering(ttl: 0)) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      fingerly.flush

      assert_equal 1, api.requests.size
      assert_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
    end
  end

  def test_a_new_rules_version_drops_every_answer
    FakeAPI.run(answering(rules: "r1")) do |api|
      fingerly = sightings(api)
      fingerly.report(env(user_agent: "a"))
      fingerly.flush
      api.handler = answering(rules: "r2")
      fingerly.report(env(user_agent: "b"))
      fingerly.flush

      assert_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env(user_agent: "a"))
      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env(user_agent: "b"))
    end
  end

  def test_the_same_rules_version_keeps_earlier_answers
    FakeAPI.run(answering(rules: "r1")) do |api|
      fingerly = sightings(api)
      fingerly.report(env(user_agent: "a"))
      fingerly.flush
      fingerly.report(env(user_agent: "b"))
      fingerly.flush

      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env(user_agent: "a"))
    end
  end

  def test_repeats_fold_into_one_item_with_a_count
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      3.times { fingerly.report(env) }
      fingerly.report(env(user_agent: "other"))
      fingerly.flush
      items = items_of(api.requests.first)

      assert_equal([3, 1], items.map { |item| item["count"] })
    end
  end

  # The console counts the requests the cache answered too.
  def test_cache_hits_are_counted_into_the_next_report
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      fingerly.flush

      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
      2.times { fingerly.report(env) }
      fingerly.flush

      assert_equal 2, api.requests.size
      assert_equal([2], items_of(api.requests.last).map { |item| item["count"] })
    end
  end

  def test_lookup_alone_reports_nothing
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      3.times { fingerly.lookup(env) }
      fingerly.flush

      assert_empty api.requests
    end
  end

  def test_signed_requests_are_never_folded
    FakeAPI.run(answering(ttl: 0)) do |api|
      fingerly = sightings(api)
      2.times { fingerly.report(signed_env) }
      fingerly.flush

      assert_equal([1, 1], items_of(api.requests.first).map { |item| item["count"] })
    end
  end

  def test_signed_needs_both_signature_headers
    only_signature = env(signature: "sig1=:abc:", signature_agent: '"https://chatgpt.com"')
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      2.times { fingerly.report(only_signature) }
      fingerly.flush

      assert_equal([2], items_of(api.requests.first).map { |item| item["count"] })
      # Cached like any unsigned request.
      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(only_signature)
    end
  end

  def test_a_blank_signature_header_is_absent
    blank = env(signature: " ", signature_input: "\t", signature_agent: "  ")
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      2.times { fingerly.report(blank) }
      fingerly.flush
      sent = items_of(api.requests.first)

      # Unsigned, so folded, and sent without the blank fields.
      assert_equal([2], sent.map { |item| item["count"] })
      %w[signature signature_input signature_agent].each { |field| refute sent[0].key?(field) }
      # Its key is that of the same request without them.
      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
    end
  end

  def test_a_count_stops_at_the_server_limit
    FakeAPI.run(status(429, "retry-after" => "3600")) do |api|
      fingerly = sightings(api)
      buffer = fingerly.instance_variable_get(:@buffer)
      fingerly.report(env)
      buffer.instance_variable_get(:@items).each_value { |item| item.hits = 999_999 }
      3.times { fingerly.report(env) }

      assert_equal [1_000_000], buffer.instance_variable_get(:@items).values.map(&:hits)
    end
  end

  def test_flushes_on_its_own_at_two_hundred_items
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      200.times { |i| fingerly.report(env(user_agent: "ua-#{i}")) }

      assert eventually? { api.requests.size == 1 }, "no flush at 200 items"
      assert_equal 200, items_of(api.requests.first).size
    end
  end

  def test_flushes_on_its_own_at_sixty_four_kibibytes
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      # 4029 bytes of fields each: 16 are 64464 bytes, and the 17th crosses
      # 65536.
      16.times { |i| fingerly.report(env(user_agent: format("%04d", i) + ("x" * 4000))) }
      sleep 0.6

      assert_empty api.requests
      fingerly.report(env(user_agent: "0016#{"x" * 4000}"))

      assert eventually? { api.requests.size >= 1 }, "no flush at 64 KiB"
      # The batch stops before the item that would pass 65536 bytes.
      assert_equal 16, items_of(api.requests.first).size
    end
  end

  def test_flushes_on_its_own_two_seconds_after_the_oldest_item
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      @clock.advance(1.9)
      sleep 0.6

      assert_empty api.requests
      @clock.advance(0.1)

      assert eventually? { api.requests.size == 1 }, "no flush two seconds after the oldest item"
    end
  end

  def test_at_most_one_flush_is_in_flight
    in_flight = 0
    most = 0
    lock = Mutex.new
    handler = lambda do |req, res|
      lock.synchronize { most = [most, in_flight += 1].max }
      sleep 0.3
      lock.synchronize { in_flight -= 1 }
      answering.call(req, res)
    end
    FakeAPI.run(handler) do |api|
      fingerly = sightings(api)
      600.times { |i| fingerly.report(env(user_agent: "ua-#{i}")) }
      threads = Array.new(3) { Thread.new { fingerly.flush } }
      threads.each(&:join)

      assert(eventually? { api.requests.size == 3 })
      assert_equal 1, most
      assert_equal(600, api.requests.sum { |request| items_of(request).size })
    end
  end

  # Its five second deadline and a second of margin, and it never raises.
  def test_flush_waits_at_most_six_seconds_for_a_flush_in_flight
    fingerly = sightings("http://127.0.0.1:9")
    fingerly.instance_variable_set(:@in_flight, true)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_nil fingerly.flush
    assert_in_delta 6, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, 0.5
  ensure
    fingerly&.instance_variable_set(:@in_flight, false)
  end

  def test_the_buffer_holds_at_most_a_thousand_items_and_counts_the_rest
    FakeAPI.run(status(429, "retry-after" => "3600")) do |api|
      fingerly = sightings(api)
      fingerly.report(env(user_agent: "first"))
      fingerly.flush
      999.times { |i| fingerly.report(env(user_agent: "ua-#{i}")) }

      assert_equal 0, fingerly.dropped_count
      fingerly.report(env(user_agent: "one too many"))
      fingerly.report(signed_env)

      assert_equal 2, fingerly.dropped_count
      # Keys already pending keep counting.
      fingerly.report(env(user_agent: "first"))

      assert_equal 2, fingerly.dropped_count
      assert_same Fingerly::AgentSightings::UNKNOWN,
                  fingerly.lookup(env(user_agent: "one too many"))
    end
  end

  def test_a_header_over_the_limit
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      long = "x" * 4097
      fingerly.report(env(user_agent: long))
      fingerly.flush

      # A user agent over the limit is not reported at all.
      assert_empty api.requests
      assert_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env(user_agent: long))

      # A signature header over the limit is left out; Host goes as received.
      fingerly.report(env(signature: long, signature_input: "sig1=()", host: long))
      fingerly.report(env(user_agent: "second", signature: "x" * 4096, signature_agent: long))
      fingerly.flush
      sent = items_of(api.requests.first)

      refute sent[0].key?("signature")
      assert_equal long, sent[0]["host"]
      assert_equal "sig1=()", sent[0]["signature_input"]
      assert_equal 4096, sent[1]["signature"].bytesize
      refute sent[1].key?("signature_agent")
    end
  end

  def test_a_request_without_a_usable_client_address_is_not_reported
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      ["203.0.113.7, 10.0.0.1", "", nil, "fe80::1%en0", "203.0.113.7:443"].each do |ip|
        fingerly.report(env(ip: ip))

        assert_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env(ip: ip))
      end
      fingerly.flush

      assert_empty api.requests
      assert_equal(1, @logger.lines.count { |line| line.include?("client_ip") })
      # At most once a minute, and never the value itself.
      @clock.advance(60)
      fingerly.report(env(ip: "203.0.113.7, 10.0.0.1"))

      assert_equal(2, @logger.lines.count { |line| line.include?("client_ip") })
      @logger.lines.each { |line| refute_includes line, "203.0.113.7" }
    end
  end

  def test_an_absent_host_is_left_out
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      fingerly.report(env.except("HTTP_HOST"))
      fingerly.flush

      refute items_of(api.requests.first).first.key?("host")
    end
  end

  def test_a_raising_client_ip_callback_answers_unknown
    FakeAPI.run(answering) do |api|
      fingerly = Fingerly::AgentSightings.new(
        secret_key: SECRET_KEY, endpoint: api.origin, allow_insecure_loopback: true,
        client_ip: ->(_request) { raise "boom" }, logger: @logger
      )
      @made << fingerly

      assert_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
      assert_nil fingerly.report(env)
    end
  end

  def test_lookup_and_report_never_raise
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)

      assert_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(Object.new)
      assert_nil fingerly.report(Object.new)
      assert_nil fingerly.report(nil)
    end
  end

  def test_refuses_a_key_that_is_not_secret_and_a_missing_callback
    assert_raises(Fingerly::ConfigurationError) do
      Fingerly::AgentSightings.new(secret_key: "fly_pk_production_x", client_ip: ->(_r) {})
    end
    assert_raises(Fingerly::ConfigurationError) do
      Fingerly::AgentSightings.new(secret_key: SECRET_KEY, client_ip: nil)
    end
  end

  def test_never_prints_its_key
    FakeAPI.run(answering) do |api|
      refute_includes sightings(api).inspect, SECRET_KEY
    end
  end

  def test_close_flushes_what_is_pending_and_ignores_later_reports
    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      fingerly.report(env)
      fingerly.close

      assert_equal 1, api.requests.size
      fingerly.report(env(user_agent: "late"))
      fingerly.flush

      assert_equal 1, api.requests.size
      refute_same Fingerly::AgentSightings::UNKNOWN, fingerly.lookup(env)
    end
  end

  def test_a_forked_child_reports_only_its_own_requests
    skip "fork is not available" unless Process.respond_to?(:fork)

    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      fingerly.report(env(user_agent: "parent"))
      pid = fork do
        fingerly.report(env(user_agent: "child"))
        # Two hundred more start the child's own background thread.
        200.times { |i| fingerly.report(env(user_agent: "child-#{i}")) }
        sleep 1.5
        fingerly.flush
        exit!(0)
      end
      Process.wait(pid)
      fingerly.flush
      sent = api.requests.flat_map { |request| items_of(request).map { |item| item["user_agent"] } }

      assert_equal 1, sent.count("parent")
      assert_equal 1, sent.count("child")
      assert_equal 202, sent.size
    end
  end

  # A worker that serves nothing, then closes at exit, must not send what its
  # parent still holds: the parent sends that itself.
  def test_a_forked_child_that_closes_does_not_send_its_parents_reports
    skip "fork is not available" unless Process.respond_to?(:fork)

    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      fingerly.report(env(user_agent: "parent"))
      pid = fork do
        fingerly.close
        exit!(0)
      end
      Process.wait(pid)

      assert_empty api.requests
      fingerly.close
      sent = api.requests.flat_map { |request| items_of(request).map { |item| item["user_agent"] } }

      assert_equal ["parent"], sent
    end
  end

  # Ruby refuses a Mutex inside a signal handler; a close from trap("TERM")
  # still sends what is pending.
  def test_close_and_flush_work_from_a_signal_handler
    skip "fork is not available" unless Process.respond_to?(:fork)

    FakeAPI.run(answering) do |api|
      fingerly = sightings(api)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        Signal.trap("USR1") { fingerly.flush }
        Signal.trap("TERM") do
          fingerly.close
          exit!(0)
        end
        fingerly.report(env(user_agent: "flushed"))
        Process.kill("USR1", Process.pid)
        sleep 0.5
        fingerly.report(env(user_agent: "closed"))
        writer.puts "ready"
        sleep 10
        exit!(1)
      end
      writer.close
      reader.gets

      assert_equal 1, api.requests.size
      Process.kill("TERM", pid)
      _, status = Process.wait2(pid)
      sent = api.requests.flat_map { |request| items_of(request).map { |item| item["user_agent"] } }

      assert_equal %w[flushed closed], sent
      assert_predicate status, :success?
    end
  end
end
