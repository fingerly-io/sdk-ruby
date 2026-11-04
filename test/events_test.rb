# frozen_string_literal: true

require "test_helper"

class EventsTest < Minitest::Test
  SECRET_KEY = "fly_sk_staging_abc123"
  EVENT_JSON = '{"request_id":"r1","visitor_id":"v1",' \
               '"occurred_at":"2026-01-02T03:04:05Z","extra":1}'
  EMPTY_PAGE = '{"rows":[],"page":1,"page_size":50}'
  NOT_FOUND = '{"error":{"code":"event_not_found"},"request_id":"trace"}'
  PENDING = '{"error":{"code":"event_pending"},"request_id":"trace"}'

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

  # A missing event (never issued, or past retention) is raised at once, in
  # one request, rather than waited through.
  def test_reports_a_missing_event_without_retrying
    FakeAPI.run(FakeAPI.json(404, NOT_FOUND)) do |api|
      error = assert_raises(Fingerly::APIError) do
        client(api).events.get("r1")
      end

      assert_equal 404, error.status
      assert_predicate error, :event_not_found?
      refute_predicate error, :pending?
      assert_equal "trace", error.request_id
      assert_equal 1, api.requests.size
    end
  end

  # An accepted request id whose event is still being recorded is a 404 of
  # its own: an API error carrying Retry-After, distinct from a missing event,
  # and never retried by the SDK.
  def test_reports_a_pending_event_with_retry_after_without_retrying
    handler = lambda do |_req, res|
      res.status = 404
      res["content-type"] = "application/json"
      res["retry-after"] = "2"
      res.body = PENDING
    end
    FakeAPI.run(handler) do |api|
      error = assert_raises(Fingerly::APIError) do
        client(api).events.get("r1")
      end

      assert_equal 404, error.status
      assert_equal "event_pending", error.code
      assert_predicate error, :pending?
      refute_predicate error, :event_not_found?
      assert_equal 2, error.retry_after
      assert_equal 1, api.requests.size
    end
  end

  def test_pending_is_narrow
    FakeAPI.run(FakeAPI.json(429, PENDING)) do |api|
      error = assert_raises(Fingerly::APIError) { client(api).events.get("r1") }

      refute_predicate error, :pending?
    end
  end

  def test_propagates_every_other_failure
    [400, 403, 429, 500].each do |status|
      FakeAPI.run(FakeAPI.json(status, '{"error":{"code":"other"}}')) do |api|
        error = assert_raises(Fingerly::APIError) do
          client(api).events.get("r1")
        end

        assert_equal status, error.status
        refute_predicate error, :event_not_found?
        refute_predicate error, :pending?
        assert_equal 1, api.requests.size
      end
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
