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
  PROXY_KEY = "fly_px_eu_production_proxy"
  PUBLIC_KEY = "fly_pk_eu_production_browser"
  PREFIX = "/metrics"
  IDENTIFY = "#{PREFIX}/api/v1/identify".freeze

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
        proxy_key: PROXY_KEY, secret_key: "fly_sk_eu_production_secret",
        client_ip: ->(_r) { "203.0.113.7" }
      )
    end
  end

  def test_refuses_a_key_that_is_not_a_proxy_key
    %w[fly_sk_eu_production_secret fly_pk_eu_production_browser nonsense].each do |key|
      assert_raises(Fingerly::ConfigurationError, "accepted #{key}") do
        Fingerly::Proxy.new(proxy_key: key, client_ip: ->(_r) { "203.0.113.7" })
      end
    end
  end

  def test_refuses_a_prefix_that_is_not_a_path
    ["metrics", "/metrics?x=1", "/metrics#x"].each do |prefix|
      assert_raises(Fingerly::ConfigurationError, "accepted #{prefix}") do
        Fingerly::Proxy.new(
          proxy_key: PROXY_KEY, prefix: prefix, client_ip: ->(_r) { "203.0.113.7" }
        )
      end
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
    "#{PREFIX}/api/v1/identify" => true,
    "/api/v1/identify" => true,                        # already stripped
    "#{PREFIX}/api/v1/events/abc/supplement" => true,
    "/api/v1/events/abc/supplement" => true,
    "#{PREFIX}/api/v1/events/abc" => false,            # a read
    "#{PREFIX}/api/v1/events" => false,
    "#{PREFIX}/api/v1/events//supplement" => false,    # no id
    "#{PREFIX}/api/v1/events/a/b/supplement" => false, # two segments
    "#{PREFIX}/api/v2/identify" => false,              # another version
    "/identify" => false,
    "#{PREFIX}/api/v1/identify/extra" => false
  }.freeze

  def test_recognises_only_the_two_proxyable_routes
    proxy = build("http://127.0.0.1:9")

    ROUTES.each do |path, handled|
      assert_equal handled, proxy.handles?(path), path
    end
  end

  def test_forwards_identify_with_the_visitor_metadata
    FakeAPI.run(FakeAPI.json(200, '{"visitor_id":"v1"}')) do |api|
      response = post(
        api, IDENTIFY, '{"payload":1}',
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
      assert_equal "/api/v1/identify", sent.path
      assert_equal '{"payload":1}', sent.body

      # The browser's public key travels on, alongside the proxy's own.
      assert_equal PUBLIC_KEY, sent.header("x-api-key")
      assert_equal PROXY_KEY, sent.header("x-fingerly-proxy-key")
      assert_equal "203.0.113.7", sent.header("x-fingerly-client-ip")
      assert_equal "https://shop.example", sent.header("x-fingerly-origin")
      assert_equal "Mozilla/5.0", sent.header("x-fingerly-user-agent")
      assert_equal "idem-1", sent.header("idempotency-key")
      assert_equal "fingerly-ruby/#{Fingerly::VERSION}", sent.header("user-agent")

      # The customer's own credentials never leave their domain.
      assert_nil sent.header("cookie")
      assert_nil sent.header("authorization")
    end
  end

  def test_forwards_supplement
    FakeAPI.run(FakeAPI.json(202, "{}")) do |api|
      response = post(
        api, "#{PREFIX}/api/v1/events/abc/supplement", "{}", "HTTP_X_API_KEY" => PUBLIC_KEY
      )

      assert_equal 202, response.status
      assert_equal "/api/v1/events/abc/supplement", api.requests.first.path
    end
  end

  def test_refuses_anything_but_post
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      response = request(api).get(IDENTIFY, "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 405, response.status
      assert_equal "POST", response.headers["allow"]
      assert_empty api.requests
    end
  end

  def test_refuses_an_event_read
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      response = post(api, "#{PREFIX}/api/v1/events/abc", "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 404, response.status
      assert_empty api.requests
    end
  end

  def test_refuses_a_key_from_another_deployment
    presented = [
      nil, "", "fly_sk_eu_production_secret", "fly_px_eu_production_proxy",
      "fly_pk_us_production_browser", "fly_pk_eu_staging_browser", "nonsense"
    ]
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      presented.each do |key|
        env = key.nil? ? {} : { "HTTP_X_API_KEY" => key }
        response = post(api, IDENTIFY, "{}", **env)

        assert_equal 401, response.status, "accepted #{key.inspect}"
      end

      assert_empty api.requests
    end
  end

  def test_the_deprecated_secret_key_mode_authenticates_on_its_own
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      proxy = Fingerly::Proxy.new(
        secret_key: "fly_sk_eu_production_secret", prefix: PREFIX,
        upstream: api.origin, client_ip: ->(_r) { "203.0.113.7" }
      )
      response = Rack::MockRequest.new(Rack::Lint.new(proxy)).post(IDENTIFY, input: "{}")

      assert_equal 200, response.status
      assert_equal "fly_sk_eu_production_secret", api.requests.first.header("x-api-key")
      assert_nil api.requests.first.header("x-fingerly-proxy-key")
    end
  end

  def test_refuses_a_declared_body_over_the_limit
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      response = post(api, IDENTIFY, "a" * 4096, max: 32, "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 413, response.status
      assert_empty api.requests
    end
  end

  def test_refuses_a_streamed_body_over_the_limit
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      # No declared length, so only reading can tell.
      env = Rack::MockRequest.env_for(
        IDENTIFY, method: "POST", input: StringIO.new("a" * 4096),
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
        proxy_key: PROXY_KEY, prefix: PREFIX, upstream: api.origin,
        client_ip: ->(_r) { INJECTED_IP }
      )
      response = Rack::MockRequest.new(Rack::Lint.new(proxy))
                                  .post(IDENTIFY, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 500, response.status
      assert_empty api.requests
    end
  end

  def test_drops_a_visitor_supplied_header_that_could_not_be_repeated
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      response = post(
        api, IDENTIFY, "{}",
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
      res["x-fingerly-trace"] = "trace-1"
      res.body = '{"visitor_id":"v1"}'
    end
    FakeAPI.run(handler) do |api|
      response = post(api, IDENTIFY, "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 201, response.status
      assert_equal '{"visitor_id":"v1"}', response.body
      assert_equal "no-store", response.headers["cache-control"]
      assert_equal "trace-1", response.headers["x-fingerly-trace"]
      assert_nil response.headers["transfer-encoding"]
    end
  end

  # A relayed body must be described by the headers that go with it. Net::HTTP
  # decodes a compressed response and drops the header itself; the strip list
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
      response = post(api, IDENTIFY, "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_nil response.headers["content-encoding"]
      assert_equal answer, response.body
    end
  end

  def test_relays_a_bodiless_status_with_no_body
    FakeAPI.run(->(_req, res) { res.status = 204 }) do |api|
      response = post(api, IDENTIFY, "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 204, response.status
      assert_equal "", response.body
    end
  end

  def test_answers_bad_gateway_when_fingerly_cannot_be_reached
    proxy = build("http://127.0.0.1:9")
    response = Rack::MockRequest.new(Rack::Lint.new(proxy))
                                .post(IDENTIFY, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

    assert_equal 502, response.status
  end

  def test_answers_bad_gateway_when_fingerly_stalls
    handler = lambda do |_req, res|
      sleep 3
      res.status = 200
    end
    FakeAPI.run(handler) do |api|
      proxy = Fingerly::Proxy.new(
        proxy_key: PROXY_KEY, prefix: PREFIX, upstream: api.origin, timeout: 0.3,
        client_ip: ->(_r) { "203.0.113.7" }
      )
      response = Rack::MockRequest.new(Rack::Lint.new(proxy))
                                  .post(IDENTIFY, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 502, response.status
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

  # Rack::URLMap moves the mount into SCRIPT_NAME, so by the time the
  # middleware runs the prefix is already gone. The proxy accepts the path
  # either way for exactly this.
  def test_works_when_a_mount_already_stripped_the_prefix
    FakeAPI.run(FakeAPI.json(200, '{"visitor_id":"v1"}')) do |api|
      mapped = Rack::URLMap.new(PREFIX => build(api.origin))
      response = Rack::MockRequest.new(Rack::Lint.new(mapped))
                                  .post(IDENTIFY, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal 200, response.status
      assert_equal "/api/v1/identify", api.requests.first.path
    end
  end

  # A sub-URI deployment is a detail the configured prefix knows nothing
  # about. Matching on PATH_INFO rather than SCRIPT_NAME + PATH_INFO is what
  # keeps the same configuration working in both places.
  def test_works_under_a_sub_uri_deployment
    FakeAPI.run(FakeAPI.json(200, '{"visitor_id":"v1"}')) do |api|
      env = Rack::MockRequest.env_for(
        "/shop#{IDENTIFY}", method: "POST", input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY
      )
      env["SCRIPT_NAME"] = "/shop"
      env["PATH_INFO"] = IDENTIFY
      status, = build(api.origin).call(env)

      assert_equal 200, status
      assert_equal "/api/v1/identify", api.requests.first.path
    end
  end

  def test_reads_the_visitor_address_from_the_header_the_customer_names
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      proxy = Fingerly::Proxy.new(
        proxy_key: PROXY_KEY, prefix: PREFIX, upstream: api.origin,
        client_ip: ->(request) { request.header("CF-Connecting-IP") }
      )
      Rack::MockRequest.new(Rack::Lint.new(proxy)).post(
        IDENTIFY, input: "{}",
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
        proxy_key: PROXY_KEY, prefix: PREFIX, upstream: api.origin,
        client_ip: lambda { |request|
          seen = request
          request.peer_host
        }
      )
      Rack::MockRequest.new(Rack::Lint.new(proxy))
                       .post(IDENTIFY, input: "{}", "HTTP_X_API_KEY" => PUBLIC_KEY)

      assert_equal "POST", seen.request_method
      assert_equal IDENTIFY, seen.path
      assert_equal PUBLIC_KEY, seen.header("x-api-key")
      assert_predicate seen.headers, :frozen?
    end
  end

  private

  def build(upstream, app: nil, max_body_bytes: 1 << 20)
    Fingerly::Proxy.new(
      app,
      proxy_key: PROXY_KEY, prefix: PREFIX, upstream: upstream,
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
