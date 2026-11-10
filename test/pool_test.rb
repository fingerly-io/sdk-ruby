# frozen_string_literal: true

require "test_helper"

# The process-wide idle pool behind every client and proxy.
class PoolTest < Minitest::Test
  EVENT_JSON = '{"request_id":"r1","visitor_id":"v1","occurred_at":"2026-01-02T03:04:05Z"}'
  KEY = [:pool_test, Object.new.object_id].freeze

  def teardown
    Fingerly::Transport.drain(KEY)
  end

  def test_a_connection_idle_too_long_is_never_handed_out
    entry = idle_entry(opened_at: 0, released_at: 0)
    Fingerly::Transport.checkin(KEY, entry, 0)

    got, stale = Fingerly::Transport.checkout(KEY, Fingerly::Transport::IDLE_TIMEOUT + 1)

    assert_nil got
    assert_equal [entry], stale
  end

  # A connection held for the life of a process pins the first DNS answer.
  def test_a_connection_past_its_age_is_never_handed_out
    entry = idle_entry(opened_at: 0, released_at: Fingerly::Transport::RECYCLE_AFTER)
    Fingerly::Transport.checkin(KEY, entry, Fingerly::Transport::RECYCLE_AFTER)

    got, stale = Fingerly::Transport.checkout(KEY, Fingerly::Transport::RECYCLE_AFTER + 1)

    assert_nil got
    assert_equal [entry], stale
  end

  def test_the_pool_never_holds_more_than_its_limit
    Fingerly::Transport::MAX_IDLE.times do
      kept, = Fingerly::Transport.checkin(KEY, idle_entry, 0)

      assert kept
    end
    kept, = Fingerly::Transport.checkin(KEY, idle_entry, 0)

    refute kept, "the caller closes a connection the pool will not keep"
    assert_equal Fingerly::Transport::MAX_IDLE, Fingerly::Transport.idle_count(KEY)
  end

  # A client built per request with an inline configure_http is a new key each
  # time, and nothing would ever check that key out again.
  def test_a_destination_nobody_returns_to_gives_its_connections_up
    abandoned = [:pool_test_abandoned, Object.new.object_id].freeze
    entry = idle_entry(opened_at: 0, released_at: 0)
    # Other tests leave a real monotonic reading here; this one counts from 0.
    Fingerly::Transport.instance_variable_set(:@swept_at, nil)
    Fingerly::Transport.checkin(abandoned, entry, 0)
    later = Fingerly::Transport::IDLE_TIMEOUT + 1

    fresh = idle_entry(opened_at: later, released_at: later)
    _kept, stale = Fingerly::Transport.checkin(KEY, fresh, later)

    assert_includes stale, entry
    refute Fingerly::Transport.instance_variable_get(:@idle).key?(abandoned)
  ensure
    Fingerly::Transport.instance_variable_set(:@swept_at, nil)
  end

  # A forked worker must not write to sockets its parent also holds.
  def test_a_forked_child_starts_with_an_empty_pool
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    Fingerly::Transport.checkin(KEY, idle_entry, 0)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.write(Fingerly::Transport.idle_count(KEY).to_s)
      writer.close
      exit!(0)
    end
    writer.close
    Process.wait(pid)

    assert_equal "0", reader.read
    assert_equal 1, Fingerly::Transport.idle_count(KEY)
  end

  # Two hundred concurrent reads hand their sockets back, and the next
  # two hundred reuse them rather than opening a socket each.
  def test_a_burst_of_concurrent_requests_reuses_its_connections
    FakeAPI.run(FakeAPI.json(200, EVENT_JSON)) do |api|
      built = Queue.new
      fingerly = Fingerly::Client.new(
        secret_key: "fly_sk_production_abc123", endpoint: api.origin,
        configure_http: ->(_http) { built << :one }
      )
      2.times do
        Array.new(50) { Thread.new { 4.times { fingerly.events.get("r1") } } }.each(&:join)
      end

      assert_equal 400, api.requests.size
      assert_operator built.size, :<=, 50, "#{built.size} connections for 400 requests"
      fingerly.close
    end
  end

  private

  def idle_entry(opened_at: 0, released_at: 0)
    Fingerly::Transport::Idle.new(Object.new, opened_at, released_at)
  end
end
