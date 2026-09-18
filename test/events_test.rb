# frozen_string_literal: true

require "test_helper"

class EventsTest < Minitest::Test
  SECRET_KEY = "fly_sk_us_staging_abc123"
  EVENT_JSON = '{"request_id":"r1","visitor_id":"v1",' \
               '"occurred_at":"2026-01-02T03:04:05Z","extra":1}'
  EMPTY_PAGE = '{"rows":[],"page":1,"page_size":50}'
  NOT_FOUND = '{"error":{"code":"event_not_found"},"request_id":"trace"}'

  def test_keeps_the_response_body_as_it_arrived
    FakeAPI.run(FakeAPI.json(200, EVENT_JSON)) do |api|
      event = client(api).events.get("r1")

      # A field this SDK does not know about is still reachable.
      assert_equal 1, event.raw["extra"]
      assert_equal Time.utc(2026, 1, 2, 3, 4, 5), event.occurred_at
    end
  end

  def test_escapes_a_request_id_into_one_path_segment
    FakeAPI.run(FakeAPI.json(200, EVENT_JSON)) do |api|
      client(api).events.get("a b/../admin")

      assert_equal "/api/v1/events/a%20b%2F..%2Fadmin", api.requests.first.raw_uri
    end
  end

  def test_refuses_an_empty_request_id
    FakeAPI.run(FakeAPI.json(200, EVENT_JSON)) do |api|
      assert_raises(Fingerly::ConfigurationError) { client(api).events.get("") }

      assert_empty api.requests
    end
  end

  def test_sends_no_query_when_no_filter_is_set
    FakeAPI.run(FakeAPI.json(200, EMPTY_PAGE)) do |api|
      page = client(api).events.list

      assert_equal "/api/v1/events", api.requests.first.path
      assert_nil api.requests.first.query
      assert_equal 1, page.page
      assert_empty page.to_a
    end
  end

  def test_sends_only_the_filters_that_were_set
    FakeAPI.run(FakeAPI.json(200, EMPTY_PAGE)) do |api|
      client(api).events.list(
        from: Time.new(2026, 1, 2, 3, 4, 5, "+02:00"),
        page: 2, limit: 25, level: "high", visitor: "v 1"
      )

      query = api.requests.first.query
      # The window start is sent as UTC, whatever offset it was written in.
      assert_includes query, "from=2026-01-02T01%3A04%3A05.000Z"
      assert_includes query, "page=2"
      assert_includes query, "limit=25"
      assert_includes query, "level=high"
      assert_includes query, "visitor=v+1"
      refute_includes query, "to="
    end
  end

  def test_refuses_a_non_positive_page_or_limit
    FakeAPI.run(FakeAPI.json(200, EMPTY_PAGE)) do |api|
      fingerly = client(api)

      [{ page: 0 }, { page: -1 }, { limit: 0 }, { limit: -5 }, { page: 1.5 }].each do |filter|
        assert_raises(Fingerly::ConfigurationError, filter.inspect) do
          fingerly.events.list(**filter)
        end
      end

      assert_empty api.requests
    end
  end

  def test_refuses_a_window_bound_that_is_not_a_time
    FakeAPI.run(FakeAPI.json(200, EMPTY_PAGE)) do |api|
      assert_raises(Fingerly::ConfigurationError) do
        client(api).events.list(from: "2026-01-02")
      end
    end
  end

  def test_wait_for_returns_the_event_once_it_is_archived
    seen = 0
    mutex = Mutex.new
    handler = lambda do |_req, res|
      archived = mutex.synchronize { (seen += 1) >= 3 }
      res.status = archived ? 200 : 404
      res["content-type"] = "application/json"
      res.body = archived ? EVENT_JSON : NOT_FOUND
    end
    FakeAPI.run(handler) do |api|
      event = client(api).events.wait_for("r1", timeout: 5, interval: 0.02)

      assert_equal "r1", event.request_id
      assert_equal 3, seen
    end
  end

  def test_wait_for_retries_only_event_not_found
    FakeAPI.run(FakeAPI.json(403, '{"error":{"code":"forbidden"}}')) do |api|
      error = assert_raises(Fingerly::APIError) do
        client(api).events.wait_for("r1", timeout: 5, interval: 0.02)
      end

      assert_equal 403, error.status
      assert_equal 1, api.requests.size
    end
  end

  def test_wait_for_keeps_the_reason_it_kept_waiting
    FakeAPI.run(FakeAPI.json(404, NOT_FOUND)) do |api|
      error = assert_raises(Fingerly::TimeoutError) do
        client(api).events.wait_for("r1", timeout: 0.2, interval: 0.02)
      end

      assert_includes error.message, "r1"
      assert_kind_of Fingerly::APIError, error.cause
      assert_predicate error.cause, :event_not_found?
    end
  end

  def test_wait_for_refuses_a_non_positive_bound
    FakeAPI.run(FakeAPI.json(404, NOT_FOUND)) do |api|
      fingerly = client(api)

      [{ timeout: 0 }, { interval: 0 }, { timeout: -1 }].each do |bound|
        assert_raises(Fingerly::ConfigurationError, bound.inspect) do
          fingerly.events.wait_for("r1", **bound)
        end
      end

      assert_empty api.requests
    end
  end

  def test_an_unscored_event_does_not_read_as_zero
    body = '{"request_id":"r1","visitor_id":"v1","occurred_at":"2026-01-02T03:04:05Z",' \
           '"suspect_score":null,"triggers":[]}'
    FakeAPI.run(FakeAPI.json(200, body)) do |api|
      event = client(api).events.get("r1")

      refute_predicate event, :scored?
      assert_nil event.suspect_score
      assert_empty event.triggers
    end
  end

  def test_a_page_is_enumerable
    body = '{"rows":[{"request_id":"a","occurred_at":"2026-01-02T03:04:05Z"},' \
           '{"request_id":"b","occurred_at":"2026-01-02T03:04:06Z"}],"page":1,"page_size":50}'
    FakeAPI.run(FakeAPI.json(200, body)) do |api|
      page = client(api).events.list

      assert_equal %w[a b], page.map(&:request_id)
      assert_equal 2, page.rows.size
    end
  end

  private

  def client(api)
    Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: api.origin)
  end
end
