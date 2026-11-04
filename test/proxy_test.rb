# frozen_string_literal: true

require "test_helper"
require "rack"
require "rack/lint"
require "rack/mock_request"
require "rack/urlmap"
require "stringio"
require "zlib"

# Every response goes through Rack::Lint, which holds it to the Rack 3 spec:
# lowercase header names, no newline in a value, a body that responds to each.
# That is stricter than any assertion written by hand, and it is the reason
# there is no per-framework variant to test: Rack is the interface every Ruby
# server and framework shares.
class ProxyTest < Minitest::Test
  PROXY_KEY = "fly_px_production_proxy"
  PUBLIC_KEY = "fly_pk_production_browser"
  PATH = "/k7x2qm4a"

  # Written as escapes so the intent survives a copy and paste: a carriage
  # return and a line feed, then a header of the attacker's choosing.
  INJECTED_IP = "203.0.113.7\x0D\x0AX-Admin: yes"
  UNPRINTABLE_CONTENT_TYPE = "text/plain\x00"
  UNPRINTABLE_ORIGIN = "https://shop.example\x07"

  def test_refuses_to_start_without_a_key
    assert_raises(Fingerly::ConfigurationError) do
      Fingerly::Proxy.new(client_ip: ->(_r) { "203.0.113.7" })
    end
  end

  def test_refuses_to_start_without_a_client_ip
    assert_raises(ArgumentError) { Fingerly::Proxy.new(proxy_key: PROXY_KEY) }
    assert_raises(Fingerly::ConfigurationError) do
      Fingerly::Proxy.new(proxy_key: PROXY_KEY, client_ip: "not callable")
    end
  end

  def test_refuses_both_kinds_of_key_at_once
    assert_raises(Fingerly::ConfigurationError) do
      Fingerly::Proxy.new(
        proxy_key: PROXY_KEY, secret_key: "fly_sk_production_secret",
        client_ip: ->(_r) { "203.0.113.7" }
      )
    end
  end

  def test_refuses_a_key_that_is_not_a_proxy_key
    %w[fly_sk_production_secret fly_pk_production_browser nonsense].each do |key|
      assert_raises(Fingerly::ConfigurationError, "accepted #{key}") do
        Fingerly::Proxy.new(proxy_key: key, client_ip: ->(_r) { "203.0.113.7" })
      end
    end
  end

  def test_refuses_a_path_that_is_not_a_path
    ["k7x2qm4a", "/k7x2qm4a?x=1", "/k7x2qm4a#x", "/", "///", "", " "].each do |path|
      assert_raises(Fingerly::ConfigurationError, "accepted #{path.inspect}") do
        Fingerly::Proxy.new(
          proxy_key: PROXY_KEY, path: path, client_ip: ->(_r) { "203.0.113.7" }
        )
      end
    end
  end

  def test_normalises_the_path_it_is_given
    proxy = Fingerly::Proxy.new(
      proxy_key: PROXY_KEY, path: " /k7x2qm4a// ", client_ip: ->(_r) { "203.0.113.7" }
    )

    assert_equal PATH, proxy.path
  end

  # Middleware sees every request in the stack, so without a path it would
  # take the application's own routes from it.
  def test_refuses_to_be_middleware_without_a_path
    assert_raises(Fingerly::ConfigurationError) do
      Fingerly::Proxy.new(
        ->(_env) { [200, {}, []] }, proxy_key: PROXY_KEY, client_ip: ->(_r) { "203.0.113.7" }
      )
    end
  end

  def test_refuses_a_non_positive_body_limit
    [0, -1, 1.5].each do |limit|
      assert_raises(Fingerly::ConfigurationError, "accepted #{limit}") do
        Fingerly::Proxy.new(
          proxy_key: PROXY_KEY, max_body_bytes: limit, client_ip: ->(_r) { "203.0.113.7" }
        )
      end
    end
  end

  ROUTES = {
    PATH => true,
    "#{PATH}/" => true,                      # trailing slashes are ignored
    "#{PATH}//" => true,
    "#{PATH}/admin" => false,                # matched exactly, nothing under it
    "#{PATH}x" => false,
    "/k7x2qm4" => false,
    "/other" => false,
    "/" => false,
    "" => false,
    "/api/v1/identify" => false,             # the old routes are gone
    "/api/v1/events/abc/supplement" => false
  }.freeze

  def test_recognises_only_the_configured_path
    proxy = build("http://127.0.0.1:9")

    ROUTES.each do |path, handled|
      assert_equal handled, proxy.handles?(path), path
    end
  end

  def test_recognises_every_path_without_one_configured
    proxy = build("http://127.0.0.1:9", path: nil)

    [PATH, "/other", "/", ""].each do |path|
      assert proxy.handles?(path), "refused #{path.inspect}"
    end
  end

  def test_forwards_an_identification_with_the_visitor_metadata
    FakeAPI.run(FakeAPI.json(200, '{"visitor_id":"v1"}')) do |api|
      response = post(
        api, PATH, '{"payload":1}',
        "HTTP_X_API_KEY" => PUBLIC_KEY,
        "HTTP_ORIGIN" => "https://shop.example",
        "HTTP_USER_AGENT" => "Mozilla/5.0",
        "HTTP_IDEMPOTENCY_KEY" => "idem-1",
        "HTTP_COOKIE" => "session=secret",
        "HTTP_AUTHORIZATION" => "Bearer customer-token"
      )

      assert_equal 200, response.status
      sent = api.requests.first

      assert_equal "POST", sent.request_method
      assert_equal "/api/v1/ingest", sent.path
      assert_equal '{"payload":1}', sent.body

      # The browser's public key travels on, alongside the proxy's own.
      assert_equal PUBLIC_KEY, sent.header("x-api-key")
      assert_equal PROXY_KEY, sent.header("x-fingerly-proxy-key")
      assert_equal "203.0.113.7", sent.header("x-fingerly-client-ip")
      assert_equal "https://shop.example", sent.header("x-fingerly-origin")
      assert_equal "Mozilla/5.0", sent.header("x-fingerly-user-agent")
      assert_equal "idem-1", sent.header("idempotency-key")
      assert_equal "fingerly-ruby/#{Fingerly::VERSION}", sent.header("user-agent")
      assert_equal "ruby/#{Fingerly::VERSION}", sent.header("x-fingerly-proxy-version")

      # The customer's own credentials never leave their domain.
      assert_nil sent.header("cookie")
      assert_nil sent.header("authorization")
    end
  end

  # The deferred report goes to the same path and the same upstream URL; the
  # API tells it from an identification by its body.
  def test_forwards_the_deferred_report_to_the_same_url
    FakeAPI.run(FakeAPI.json(202, '{"request_id":"r1","duplicate":false}')) do |api|
      response = post(api, PATH, '{"token":"t1"}', "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 202, response.status
      assert_equal "/api/v1/ingest", api.requests.first.path
      assert_equal '{"token":"t1"}', api.requests.first.body
    end
  end

  def test_forwards_to_the_configured_versions_ingest_url
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      proxy = Fingerly::Proxy.new(
        proxy_key: PROXY_KEY, path: PATH, api_version: "v2", upstream: api.origin,
        client_ip: ->(_r) { "203.0.113.7" }
      )
      response = Rack::MockRequest.new(Rack::Lint.new(proxy))
                                  .post(PATH, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 200, response.status
      assert_equal "/api/v2/ingest", api.requests.first.path
    end
  end

  def test_refuses_anything_but_post
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      response = request(api).get(PATH, "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 405, response.status
      assert_equal "POST", response.headers["allow"]
      assert_empty api.requests
    end
  end

  # The path is checked before the method, so a wrong method elsewhere is not
  # told that this path exists.
  def test_refuses_another_path_before_the_method
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      ["#{PATH}/admin", "/other", "/api/v1/events/abc"].each do |path|
        assert_equal 404, post(api, path, "{}", "HTTP_X_API_KEY" => PUBLIC_KEY).status, path
        assert_equal 404, request(api).get(path).status, path
      end

      assert_empty api.requests
    end
  end

  def test_refuses_a_key_from_another_deployment
    presented = [
      nil, "", "fly_sk_production_secret", "fly_px_production_proxy",
      "fly_pk_staging_browser", "nonsense"
    ]
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      presented.each do |key|
        env = key.nil? ? {} : { "HTTP_X_API_KEY" => key }
        response = post(api, PATH, "{}", **env)

        assert_equal 401, response.status, "accepted #{key.inspect}"
      end

      assert_empty api.requests
    end
  end

  def test_the_deprecated_secret_key_mode_authenticates_on_its_own
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      proxy = Fingerly::Proxy.new(
        secret_key: "fly_sk_production_secret", path: PATH,
        upstream: api.origin, client_ip: ->(_r) { "203.0.113.7" }
      )
      response = Rack::MockRequest.new(Rack::Lint.new(proxy)).post(PATH, input: "{}")

      assert_equal 200, response.status
      assert_equal "fly_sk_production_secret", api.requests.first.header("x-api-key")
      assert_nil api.requests.first.header("x-fingerly-proxy-key")
    end
  end

  def test_refuses_a_declared_body_over_the_limit
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      response = post(api, PATH, "a" * 4096, max: 32, "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 413, response.status
      assert_empty api.requests
    end
  end

  def test_refuses_a_streamed_body_over_the_limit
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      # No declared length, so only reading can tell.
      env = Rack::MockRequest.env_for(
        PATH, method: "POST", input: StringIO.new("a" * 4096),
              "HTTP_X_API_KEY" => PUBLIC_KEY
      )
      env.delete("CONTENT_LENGTH")
      status, = build(api.origin, max_body_bytes: 32).call(env)

      assert_equal 413, status
      assert_empty api.requests
    end
  end

  def test_refuses_a_client_ip_that_could_inject_a_header
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      proxy = Fingerly::Proxy.new(
        proxy_key: PROXY_KEY, path: PATH, upstream: api.origin,
        client_ip: ->(_r) { INJECTED_IP }
      )
      response = Rack::MockRequest.new(Rack::Lint.new(proxy))
                                  .post(PATH, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 500, response.status
      assert_empty api.requests
    end
  end

  def test_drops_a_visitor_supplied_header_that_could_not_be_repeated
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      response = post(
        api, PATH, "{}",
        "HTTP_X_API_KEY" => PUBLIC_KEY,
        "CONTENT_TYPE" => UNPRINTABLE_CONTENT_TYPE,
        "HTTP_ORIGIN" => UNPRINTABLE_ORIGIN
      )

      assert_equal 200, response.status
      assert_equal "application/json", api.requests.first.header("content-type")
      assert_equal "", api.requests.first.header("x-fingerly-origin")
    end
  end

  def test_relays_the_upstream_answer_uncacheable
    handler = lambda do |_req, res|
      res.status = 201
      res["content-type"] = "application/json"
      res["cache-control"] = "public, max-age=600"
      res.body = '{"visitor_id":"v1"}'
    end
    FakeAPI.run(handler) do |api|
      response = post(api, PATH, "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 201, response.status
      assert_equal '{"visitor_id":"v1"}', response.body
      assert_equal "application/json", response.headers["content-type"]
      assert_equal "no-store", response.headers["cache-control"]
      assert_nil response.headers["transfer-encoding"]
    end
  end

  # A content blocker can match a response header by name, so only the
  # allowlist is relayed, whatever else the API sends.
  def test_relays_only_the_allowlisted_headers
    handler = lambda do |_req, res|
      res.status = 429
      res["content-type"] = "application/json"
      res["x-request-id"] = "one"
      res["ratelimit-limit"] = "100"
      res["ratelimit-remaining"] = "0"
      res["retry-after"] = "7"
      res["fingerly-balance-micros"] = "100"
      res["x-fingerly-trace"] = "trace-1"
      res["set-cookie"] = "a=b"
      res["vary"] = "origin"
      res.body = "{}"
    end
    FakeAPI.run(handler) do |api|
      response = post(api, PATH, "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 429, response.status
      relayed = response.headers.to_h.transform_keys(&:downcase)

      assert_equal(
        {
          "content-type" => "application/json", "x-request-id" => "one",
          "ratelimit-limit" => "100", "ratelimit-remaining" => "0", "retry-after" => "7",
          "cache-control" => "no-store"
        },
        relayed.except("content-length")
      )
      refute relayed.any? { |name, value| "#{name} #{value}".match?(/fingerly/i) }, relayed
    end
  end

  # A relayed body must be described by the headers that go with it. Net::HTTP
  # decodes a compressed response and drops the header itself; the allowlist
  # keeps that true for anything it does not.
  def test_does_not_repeat_the_upstream_content_encoding
    answer = '{"visitor_id":"v1"}'
    compressed = StringIO.new
    Zlib::GzipWriter.new(compressed).tap do |gz|
      gz.write(answer)
      gz.close
    end
    handler = lambda do |_req, res|
      res.status = 200
      res["content-type"] = "application/json"
      res["content-encoding"] = "gzip"
      res.body = compressed.string
    end
    FakeAPI.run(handler) do |api|
      response = post(api, PATH, "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_nil response.headers["content-encoding"]
      assert_equal answer, response.body
    end
  end

  def test_relays_a_bodiless_status_with_no_body
    FakeAPI.run(->(_req, res) { res.status = 204 }) do |api|
      response = post(api, PATH, "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 204, response.status
      assert_equal "", response.body

      env = Rack::MockRequest.env_for(PATH, method: "POST", input: "{}",
                                            "HTTP_X_API_KEY" => PUBLIC_KEY)
      _status, _headers, body = build(api.origin).call(env)

      assert_empty body, "not even one empty chunk"
    end
  end

  def test_answers_bad_gateway_when_fingerly_cannot_be_reached
    proxy = build("http://127.0.0.1:9")
    response = Rack::MockRequest.new(Rack::Lint.new(proxy))
                                .post(PATH, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

    assert_gateway_error 502, "Bad gateway", response
  end

  # Upstream trouble of every kind is a gateway error with a short plain
  # body, never the application's 500 and never a truncated success.
  UPSTREAM_FAILURES = {
    "a body cut short" =>
      "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 100\r\n\r\n{\"a\":",
    "a status line that is not one" => "garbage\r\n\r\n",
    "a gzip body that is not gzip" =>
      "HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\ncontent-length: 8\r\n\r\nnot gzip",
    "a declared body over the cap" =>
      "HTTP/1.1 200 OK\r\ncontent-length: #{(4 << 20) + 1}\r\n\r\n{}",
    "a streamed body over the cap" =>
      "HTTP/1.1 200 OK\r\nconnection: close\r\n\r\n#{" " * ((4 << 20) + 1)}"
  }.freeze

  def test_answers_bad_gateway_for_every_kind_of_upstream_failure
    UPSTREAM_FAILURES.each do |label, raw|
      RawServer.run(raw) do |server|
        response = Rack::MockRequest.new(Rack::Lint.new(build(server.origin)))
                                    .post(PATH, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

        assert_gateway_error 502, "Bad gateway", response, label
      end
    end
  end

  def test_logs_one_line_per_upstream_failure
    lines = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |line| lines << line }
    proxy = Fingerly::Proxy.new(
      proxy_key: PROXY_KEY, path: PATH, upstream: "http://127.0.0.1:9", logger: logger,
      client_ip: ->(_r) { "203.0.113.7" }
    )
    Rack::MockRequest.new(Rack::Lint.new(proxy))
                     .post(PATH, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

    assert_equal 1, lines.size
    assert_match(/\Afingerly proxy: 502 .*ECONNREFUSED/, lines.first)
    refute_includes lines.first, "\n"
    refute_includes lines.first, PROXY_KEY
  end

  def test_uses_the_rack_logger_when_none_is_given
    lines = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |line| lines << line }
    Rack::MockRequest.new(build("http://127.0.0.1:9")).post(
      PATH, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY, "rack.logger" => logger
    )

    assert_equal 1, lines.size
  end

  def test_refuses_a_logger_that_cannot_log
    assert_raises(Fingerly::ConfigurationError) do
      Fingerly::Proxy.new(proxy_key: PROXY_KEY, path: PATH, logger: Object.new,
                          client_ip: ->(_r) { "203.0.113.7" })
    end
  end

  # A visitor who goes away mid-upload leaves nobody to answer; the proxy
  # ends quietly instead of raising into the application.
  def test_ends_quietly_when_the_visitor_disconnects_mid_body
    input = Object.new
    input.define_singleton_method(:read) { |*_args| raise EOFError, "client went away" }
    env = Rack::MockRequest.env_for(PATH, method: "POST", "HTTP_X_API_KEY" => PUBLIC_KEY)
    env["rack.input"] = input
    status, = build("http://127.0.0.1:9").call(env)

    assert_equal 400, status
  end

  def test_answers_gateway_timeout_when_fingerly_stalls
    handler = lambda do |_req, res|
      sleep 3
      res.status = 200
    end
    FakeAPI.run(handler) do |api|
      proxy = Fingerly::Proxy.new(
        proxy_key: PROXY_KEY, path: PATH, upstream: api.origin, timeout: 0.3,
        client_ip: ->(_r) { "203.0.113.7" }
      )
      response = Rack::MockRequest.new(Rack::Lint.new(proxy))
                                  .post(PATH, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_gateway_error 504, "Gateway timeout", response
    end
  end

  def test_the_deadline_covers_the_upstream_headers
    TricklingServer.run(interval: 0.2, lines: 50) do |server|
      proxy = Fingerly::Proxy.new(
        proxy_key: PROXY_KEY, path: PATH, upstream: server.origin, timeout: 0.75,
        client_ip: ->(_r) { "203.0.113.7" }
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Rack::MockRequest.new(Rack::Lint.new(proxy))
                                  .post(PATH, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 504, response.status
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    end
  end

  # The trap this middleware exists to avoid. Reading the body to find out
  # whether a request is Fingerly's would leave the application nothing to
  # read: under Rack 3 the input stream is not required to rewind.
  def test_passes_another_route_along_with_its_body_intact
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      app = lambda do |env|
        [200, { "content-type" => "text/plain" }, ["app read: #{env["rack.input"].read}"]]
      end
      proxy = build(api.origin, app: app)
      response = Rack::MockRequest.new(Rack::Lint.new(proxy))
                                  .post("/orders", input: '{"order":1}')

      assert_equal 200, response.status
      assert_equal 'app read: {"order":1}', response.body
      assert_empty api.requests
    end
  end

  def test_answers_not_found_for_another_route_when_mounted_alone
    proxy = build("http://127.0.0.1:9")
    response = Rack::MockRequest.new(Rack::Lint.new(proxy)).post("/orders", input: "{}")

    assert_equal 404, response.status
  end

  # Rack::URLMap, like a Rails mount, routes the path here and moves it into
  # SCRIPT_NAME, so the proxy takes no path of its own.
  def test_answers_where_a_mount_routes_it_without_a_path
    FakeAPI.run(FakeAPI.json(200, '{"visitor_id":"v1"}')) do |api|
      mapped = Rack::URLMap.new(PATH => build(api.origin, path: nil))
      response = Rack::MockRequest.new(Rack::Lint.new(mapped))
                                  .post(PATH, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 200, response.status
      assert_equal "/api/v1/ingest", api.requests.first.path
    end
  end

  # A sub-URI deployment is a detail the configured path knows nothing
  # about. Matching on PATH_INFO rather than SCRIPT_NAME + PATH_INFO is what
  # keeps the same configuration working in both places.
  def test_works_under_a_sub_uri_deployment
    FakeAPI.run(FakeAPI.json(200, '{"visitor_id":"v1"}')) do |api|
      env = Rack::MockRequest.env_for(
        "/shop#{PATH}", method: "POST", input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY
      )
      env["SCRIPT_NAME"] = "/shop"
      env["PATH_INFO"] = PATH
      status, = build(api.origin).call(env)

      assert_equal 200, status
      assert_equal "/api/v1/ingest", api.requests.first.path
    end
  end

  def test_reads_the_visitor_address_from_the_header_the_customer_names
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      proxy = Fingerly::Proxy.new(
        proxy_key: PROXY_KEY, path: PATH, upstream: api.origin,
        client_ip: ->(request) { request.header("CF-Connecting-IP") }
      )
      Rack::MockRequest.new(Rack::Lint.new(proxy)).post(
        PATH, input: "{}",
              "HTTP_X_API_KEY" => PUBLIC_KEY,
              "HTTP_CF_CONNECTING_IP" => "198.51.100.9",
              "HTTP_X_FORWARDED_FOR" => "10.0.0.1, 198.51.100.9"
      )

      assert_equal "198.51.100.9", api.requests.first.header("x-fingerly-client-ip")
    end
  end

  def test_the_request_shows_what_client_ip_has_to_work_with
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      seen = nil
      proxy = Fingerly::Proxy.new(
        proxy_key: PROXY_KEY, path: PATH, upstream: api.origin,
        client_ip: lambda { |request|
          seen = request
          request.peer_host
        }
      )
      Rack::MockRequest.new(Rack::Lint.new(proxy))
                       .post(PATH, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal "POST", seen.request_method
      assert_equal PATH, seen.path
      assert_equal PUBLIC_KEY, seen.header("x-api-key")
      assert_predicate seen.headers, :frozen?
    end
  end

  private

  def assert_gateway_error(status, text, response, label = nil)
    assert_equal status, response.status, label
    assert_equal text, response.body, label
    assert_equal "no-store", response.headers["cache-control"], label
    assert_match %r{\Atext/plain}, response.headers["content-type"], label
    refute_match(/fingerly/i, response.body, label)
  end

  def build(upstream, app: nil, path: PATH, max_body_bytes: 1 << 20)
    Fingerly::Proxy.new(
      app,
      proxy_key: PROXY_KEY, path: path, upstream: upstream,
      max_body_bytes: max_body_bytes, client_ip: ->(_r) { "203.0.113.7" }
    )
  end

  def request(api, max: 1 << 20)
    Rack::MockRequest.new(Rack::Lint.new(build(api.origin, max_body_bytes: max)))
  end

  def post(api, path, body, max: 1 << 20, **env)
    request(api, max: max).post(path, input: body, **env)
  end
end
