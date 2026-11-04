# frozen_string_literal: true

require "test_helper"
require "async"

# Why there is no asynchronous client to go with the synchronous one.
#
# The Python SDK ships two, because ASGI and WSGI are two live server standards
# and a blocking call inside FastAPI stalls its event loop. Ruby has one server
# interface, Rack, and every framework on it calls the application
# synchronously. Under the one Ruby stack that is not thread-per-request,
# Net::HTTP has honoured the fiber scheduler since Ruby 3.0, so the same
# blocking client is already non-blocking there.
#
# Both halves of that are asserted here rather than claimed in a comment.
class ConcurrencyTest < Minitest::Test
  SECRET_KEY = "fly_sk_production_abc123"
  EVENT_JSON = '{"request_id":"r1","visitor_id":"v1","occurred_at":"2026-01-02T03:04:05Z"}'
  DELAY = 0.3
  CALLS = 5

  def test_requests_overlap_under_a_fiber_scheduler
    FakeAPI.run(slow_handler) do |api|
      fingerly = Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: api.origin)

      elapsed = measure do
        Async do
          CALLS.times.map { Async { fingerly.events.get("r1") } }.each(&:wait)
        end
      end

      assert_equal CALLS, api.requests.size
      # Serialised, this would take CALLS * DELAY. Anything under half of that
      # means the scheduler took the socket waits over.
      assert_operator elapsed, :<, CALLS * DELAY / 2,
                      "#{CALLS} calls took #{elapsed.round(2)}s; they did not overlap"
    end
  end

  def test_requests_overlap_across_threads
    FakeAPI.run(slow_handler) do |api|
      fingerly = Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: api.origin)

      elapsed = measure do
        CALLS.times.map { Thread.new { fingerly.events.get("r1") } }.each(&:join)
      end

      assert_equal CALLS, api.requests.size
      assert_operator elapsed, :<, CALLS * DELAY / 2,
                      "#{CALLS} calls took #{elapsed.round(2)}s; they did not overlap"
    end
  end

  # Net::HTTP cannot be shared, so fibers running at the same time each need a
  # connection of their own. Afterwards the pool holds all of them.
  def test_concurrent_fibers_each_get_their_own_connection
    FakeAPI.run(slow_handler) do |api|
      built = Queue.new
      fingerly = Fingerly::Client.new(
        secret_key: SECRET_KEY, endpoint: api.origin,
        configure_http: ->(_http) { built << :one }
      )

      Async do
        CALLS.times.map { Async { fingerly.events.get("r1") } }.each(&:wait)
      end

      assert_equal CALLS, built.size
      fingerly.close
    end
  end

  # Falcon runs each client connection in a fiber of its own, and a fiber
  # that ends must hand its socket back. Twenty fibers one after another, as
  # twenty visitors would be, share one upstream connection.
  def test_fibers_one_after_another_share_one_connection
    FakeAPI.run(FakeAPI.json(200, EVENT_JSON)) do |api|
      built = Queue.new
      fingerly = Fingerly::Client.new(
        secret_key: SECRET_KEY, endpoint: api.origin,
        configure_http: ->(_http) { built << :one }
      )

      Async do
        20.times { Async { fingerly.events.get("r1") }.wait }
      end

      assert_equal 20, api.requests.size
      assert_equal 1, built.size
      fingerly.close
    end
  end

  # Puma may start and retire threads; a thread that ends hands its socket on.
  def test_threads_one_after_another_share_one_connection
    FakeAPI.run(FakeAPI.json(200, EVENT_JSON)) do |api|
      built = Queue.new
      fingerly = Fingerly::Client.new(
        secret_key: SECRET_KEY, endpoint: api.origin,
        configure_http: ->(_http) { built << :one }
      )

      5.times { Thread.new { fingerly.events.get("r1") }.join }

      assert_equal 1, built.size
      fingerly.close
    end
  end

  private

  def slow_handler
    lambda do |_req, res|
      sleep DELAY
      res.status = 200
      res["content-type"] = "application/json"
      res.body = EVENT_JSON
    end
  end

  def measure
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end
end
