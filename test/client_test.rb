# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  SECRET_KEY = "fly_sk_eu_production_abc123"
  EVENT_JSON = '{"request_id":"r1","visitor_id":"v1","occurred_at":"2026-01-02T03:04:05Z"}'

  NOT_SECRET_KEYS = [
    "",
    "nonsense",
    "fly_pk_eu_production_abc",      # a browser key
    "fly_px_eu_production_abc",      # a proxy key
    "fly_mk_eu_production_abc",      # a management key
    "fly_sk_ap_production_abc",      # an unknown region
    "fly_sk_eu_sandbox_abc",         # an unknown environment
    "fly_sk_eu_production_",         # no suffix
    "fly_sk_eu_production_abc\n"     # a trailing newline
  ].freeze

  def test_refuses_every_key_that_is_not_a_secret_key
    NOT_SECRET_KEYS.each do |key|
      error = assert_raises(Fingerly::ConfigurationError, "accepted #{key.inspect}") do
        Fingerly::Client.new(secret_key: key)
      end
      assert_includes error.message, "secret key"
    end
  end

  def test_validates_the_key_even_when_an_endpoint_is_given
    # Otherwise a local endpoint would be a way to smuggle a browser key into
    # an API that accepts one.
    assert_raises(Fingerly::ConfigurationError) do
      Fingerly::Client.new(secret_key: "fly_pk_eu_production_abc", endpoint: "http://127.0.0.1:9")
    end
  end

  def test_refuses_an_unusable_endpoint
    [
      "ftp://api.fingerly.io",
      "https://user:pass@api.fingerly.io",
      "https://api.fingerly.io?token=1",
      "https://api.fingerly.io#fragment",
      "not a url"
    ].each do |endpoint|
      assert_raises(Fingerly::ConfigurationError, "accepted #{endpoint}") do
        Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: endpoint)
      end
    end
  end

  def test_refuses_an_unusable_api_version
    ["v", "1", "v0", "v1/../admin"].each do |version|
      assert_raises(Fingerly::ConfigurationError, "accepted #{version}") do
        Fingerly::Client.new(secret_key: SECRET_KEY, api_version: version)
      end
    end
  end

  def test_refuses_a_non_positive_timeout
    [0, -1, nil, "10"].each do |timeout|
      assert_raises(Fingerly::ConfigurationError, "accepted #{timeout.inspect}") do
        Fingerly::Client.new(secret_key: SECRET_KEY, timeout: timeout)
      end
    end
  end

  def test_sends_the_key_and_version_on_every_request
    FakeAPI.run(FakeAPI.json(200, EVENT_JSON)) do |api|
      client(api).events.get("r1")

      sent = api.requests.first

      assert_equal "GET", sent.request_method
      assert_equal "/api/v1/events/r1", sent.path
      assert_equal SECRET_KEY, sent.header("x-api-key")
      assert_equal "application/json", sent.header("accept")
      assert_equal "fingerly-ruby/#{Fingerly::VERSION}", sent.header("user-agent")
    end
  end

  def test_never_retries_a_failed_read
    FakeAPI.run(FakeAPI.json(500, '{"error":{"code":"boom"}}')) do |api|
      assert_raises(Fingerly::APIError) { client(api).events.get("r1") }

      assert_equal 1, api.requests.size
    end
  end

  def test_redacts_the_secret_key_from_error_metadata
    leaked = JSON.generate(
      "error" => { "code" => "bad_#{SECRET_KEY}", "details" => { "nested" => [SECRET_KEY] } },
      "request_id" => SECRET_KEY
    )
    FakeAPI.run(FakeAPI.json(400, leaked)) do |api|
      error = assert_raises(Fingerly::APIError) { client(api).events.get("r1") }

      refute_includes error.code, SECRET_KEY
      refute_includes error.request_id, SECRET_KEY
      refute_includes JSON.generate(error.details), SECRET_KEY
      refute_includes error.message, SECRET_KEY
    end
  end

  def test_reports_the_status_when_the_error_body_is_not_json
    handler = lambda do |_req, res|
      res.status = 503
      res.body = "<html>gateway</html>"
    end
    FakeAPI.run(handler) do |api|
      error = assert_raises(Fingerly::APIError) { client(api).events.get("r1") }

      assert_equal 503, error.status
      assert_nil error.code
      # The body is never echoed, whatever it was.
      refute_includes error.message, "gateway"
    end
  end

  # The deadline has to cover the body, not only the headers. Net::HTTP's own
  # read_timeout bounds one read, so a server that answers and then dribbles
  # would satisfy it forever.
  def test_the_deadline_covers_receiving_the_body
    handler = lambda do |_req, res|
      res.status = 200
      res["content-type"] = "application/json"
      reader, writer = IO.pipe
      res.body = reader
      res.chunked = true
      Thread.new do
        writer.write('{"request_id":')
        writer.flush
        sleep 3
        writer.close
      end
    end
    FakeAPI.run(handler) do |api|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Fingerly::TimeoutError) do
        client(api, timeout: 0.75).events.get("r1")
      end

      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
    end
  end

  def test_does_not_follow_a_redirect
    handler = lambda do |_req, res|
      res.status = 302
      res["location"] = "https://evil.example/api/v1/events/r1"
    end
    FakeAPI.run(handler) do |api|
      error = assert_raises(Fingerly::APIError) { client(api).events.get("r1") }

      assert_equal 302, error.status
      assert_equal 1, api.requests.size
    end
  end

  # One connection per thread, reused. configure_http runs once per connection
  # built, so counting it counts connections.
  def test_reuses_one_connection_per_thread
    FakeAPI.run(FakeAPI.json(200, EVENT_JSON)) do |api|
      built = 0
      fingerly = Fingerly::Client.new(
        secret_key: SECRET_KEY, endpoint: api.origin,
        configure_http: ->(_http) { built += 1 }
      )
      3.times { fingerly.events.get("r1") }

      assert_equal 1, built
      assert_equal 3, api.requests.size
      fingerly.close
    end
  end

  # A server may close a kept-alive connection whenever it likes. Net::HTTP
  # only notices if it is allowed to finish its own bookkeeping after the
  # response, which is why the body is read into a local rather than returned
  # from inside its block.
  def test_recovers_when_the_server_closes_the_connection
    handler = lambda do |_req, res|
      res.keep_alive = false
      res.status = 200
      res["content-type"] = "application/json"
      res.body = EVENT_JSON
    end
    FakeAPI.run(handler) do |api|
      fingerly = client(api)

      3.times { assert_equal "r1", fingerly.events.get("r1").request_id }

      assert_equal 3, api.requests.size
      fingerly.close
    end
  end

  def test_reports_an_unreachable_api_as_a_connection_failure
    # Port 9 is discard; nothing listens on it.
    fingerly = Fingerly::Client.new(
      secret_key: SECRET_KEY, endpoint: "http://127.0.0.1:9", timeout: 5
    )
    assert_raises(Fingerly::ConnectionError) { fingerly.events.get("r1") }
  end

  private

  def client(api, timeout: 10)
    Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: api.origin, timeout: timeout)
  end
end
