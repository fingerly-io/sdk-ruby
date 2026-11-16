# frozen_string_literal: true

# Regression tests for the proxy contract (sdks/contract/proxy.md): channel
# headers, upstream validation, exact path and method, status range, redirects,
# no-store on every local answer, and what failure lines reveal. Local only:
# every mock upstream listens on 127.0.0.1.

require "test_helper"
require "rack"
require "rack/lint"
require "rack/mock_request"
require "rack/urlmap"
require "stringio"
require "zlib"
require "logger"
require "yaml"
require "pp"

class ProxyHardeningTest < Minitest::Test
  PROXY_KEY = "fly_px_production_AUDITSECRETKEYVALUE"
  PUBLIC_KEY = "fly_pk_production_browser"
  PATH = "/k7x2qm4a"
  QUIET = Logger.new(File::NULL)
  IP = "203.0.113.7"

  ALLOWED_UPSTREAM = %w[
    content-type x-api-key x-fingerly-client-ip x-fingerly-user-agent
    x-fingerly-proxy-version user-agent x-fingerly-origin x-fingerly-sdk-platform
    x-fingerly-host x-fingerly-proxy-key idempotency-key sec-fetch-site sec-fetch-mode
    sec-fetch-dest sec-ch-ua sec-ch-ua-mobile sec-ch-ua-platform
    accept accept-encoding host content-length connection
  ].freeze

  # Counts connections and requests; answers with whatever the block says.
  class CountingServer
    attr_reader :connections, :requests

    def initialize(&script)
      @connections = 0
      @requests = 0
      @server = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new do
        loop do
          client = @server.accept
          @connections += 1
          Thread.new(client) { |c| serve(c, script) }
        end
      rescue IOError, SystemCallError
        nil
      end
    end

    def origin = "http://127.0.0.1:#{@server.addr[1]}"

    def shutdown
      @server.close
      @thread.join(1)
    end

    private

    def serve(client, script)
      loop do
        data = +""
        data << client.readpartial(4096) until data.include?("\r\n\r\n")
        head, rest = data.split("\r\n\r\n", 2)
        length = head[/^content-length:\s*(\d+)/i, 1].to_i
        rest << client.readpartial(4096) while rest.bytesize < length
        @requests += 1
        break unless script.call(client, @requests)
      end
    rescue IOError, SystemCallError
      nil
    ensure
      client.close unless client.closed?
    end
  end

  def build(upstream, **options)
    Fingerly::Proxy.new(
      options.delete(:app),
      proxy_key: PROXY_KEY, path: PATH, upstream: upstream, logger: QUIET,
      allow_insecure_loopback: true, client_ip: ->(_r) { IP }, **options
    )
  end

  def env_for(uri = PATH, method: "POST", body: "{}", **headers)
    merged = { "HTTP_X_API_KEY" => PUBLIC_KEY,
               "HTTP_ORIGIN" => "https://shop.example" }.merge(headers)
    merged.delete_if { |_k, v| v.nil? }
    Rack::MockRequest.env_for(uri, method: method, input: body, **merged)
  end

  def body_of(response)
    out = +""
    response[2].each { |part| out << part }
    out
  end

  # ---- channel and upstream -------------------------------------------------

  def test_an_origin_wins_and_the_platform_is_not_forwarded_with_it
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      status, = build(api.origin).call(env_for("HTTP_X_FINGERLY_SDK_PLATFORM" => "ios"))
      seen = api.requests.first

      assert_equal 200, status
      assert_equal "https://shop.example", seen.header("x-fingerly-origin")
      assert_nil seen.header("x-fingerly-sdk-platform")
    end
  end

  def test_a_platform_without_an_origin_is_forwarded_alone
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      build(api.origin).call(env_for("HTTP_ORIGIN" => nil, "HTTP_X_FINGERLY_SDK_PLATFORM" => "ios"))
      seen = api.requests.first

      assert_equal "ios", seen.header("x-fingerly-sdk-platform")
      assert_nil seen.header("x-fingerly-origin")
    end
  end

  def test_a_plain_http_upstream_is_refused_unless_loopback_and_opted_in
    # Construct only; nothing is ever sent to these names.
    ["http://upstream.invalid", "http://192.0.2.10:8080", "http://127.0.0.2", "http://[::2]",
     "http://localhost.example", "http://LOCALHOST", "HTTP://upstream.invalid"].each do |upstream|
      assert_raises(Fingerly::ConfigurationError, upstream) { build(upstream) }
    end
    ["http://127.0.0.1:9", "http://localhost:9", "http://[::1]:9"].each do |upstream|
      assert_raises(Fingerly::ConfigurationError, upstream) do
        build(upstream, allow_insecure_loopback: false)
      end
      build(upstream)
    end
    build("https://upstream.invalid", allow_insecure_loopback: false)
  end

  # ---- A: request headers --------------------------------------------------

  def test_upstream_headers_are_an_allowlist_and_smuggled_values_never_arrive
    smuggled = {
      "HTTP_X_FINGERLY_CLIENT_IP" => "6.6.6.6",
      "HTTP_X_FINGERLY_FORWARDED_FOR" => "6.6.6.6",
      "HTTP_X_FINGERLY_ORIGIN" => "https://evil.example",
      "HTTP_X_FINGERLY_PROXY_KEY" => "fly_px_production_evil",
      "HTTP_X_FINGERLY_KEY" => "fly_px_production_evil",
      "HTTP_X_FINGERLY_EDGE_TLS_VERSION" => "TLSv1.3",
      "HTTP_X_FINGERLY_EDGE_TLS_CIPHER" => "evil",
      "HTTP_X_FINGERLY_EDGE_HTTP_PROTO" => "HTTP/3",
      "HTTP_X_FINGERLY_USER_AGENT" => "evil-agent",
      "HTTP_X_FINGERLY_HOST" => "evil.example",
      "HTTP_X_FINGERLY_PROXY_VERSION" => "evil/9",
      "HTTP_X_FORWARDED_FOR" => "6.6.6.6",
      "HTTP_X_REAL_IP" => "6.6.6.6",
      "HTTP_FORWARDED" => "for=6.6.6.6",
      "HTTP_COOKIE" => "session=secret",
      "HTTP_AUTHORIZATION" => "Bearer secret",
      "HTTP_USER_AGENT" => "Mozilla/5.0 real",
      "HTTP_HOST" => "shop.example"
    }
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      status, = build(api.origin).call(env_for(**smuggled))

      assert_equal 200, status
      seen = api.requests.first

      assert_empty seen.headers.keys - ALLOWED_UPSTREAM
      assert_equal IP, seen.header("x-fingerly-client-ip")
      assert_equal "https://shop.example", seen.header("x-fingerly-origin")
      assert_equal PROXY_KEY, seen.header("x-fingerly-proxy-key")
      assert_equal "Mozilla/5.0 real", seen.header("x-fingerly-user-agent")
      assert_equal "shop.example", seen.header("x-fingerly-host")
      assert_equal "ruby/#{Fingerly::VERSION}", seen.header("x-fingerly-proxy-version")
      seen.headers.each_value { |v| refute_match(/6\.6\.6\.6|evil|secret"?\z|Bearer/, v) }
    end
  end

  def test_control_bytes_in_forwarded_values_never_reach_upstream
    inject = "x\r\nX-Fingerly-Client-IP: 6.6.6.6"
    dirty = {
      "HTTP_USER_AGENT" => inject, "HTTP_IDEMPOTENCY_KEY" => inject,
      "HTTP_SEC_FETCH_SITE" => inject, "HTTP_SEC_CH_UA_PLATFORM" => "x\ny",
      "CONTENT_TYPE" => "application/json\r\nX-A: b", "HTTP_HOST" => "h\r\nX-A: b",
      "HTTP_SEC_FETCH_MODE" => "cors\t", "HTTP_SEC_FETCH_DEST" => "café"
    }
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      status, = build(api.origin).call(env_for(**dirty))

      assert_equal 200, status
      seen = api.requests.first

      assert_equal IP, seen.header("x-fingerly-client-ip")
      assert_equal "application/json", seen.header("content-type")
      assert_nil seen.header("idempotency-key")
      assert_nil seen.header("sec-fetch-site")
      assert_nil seen.header("sec-fetch-mode")
      assert_nil seen.header("sec-fetch-dest")
      assert_nil seen.header("sec-ch-ua-platform")
      assert_nil seen.header("x-a")
      assert_empty seen.header("x-fingerly-user-agent").to_s
    end
  end

  def test_an_origin_with_control_bytes_is_not_an_origin
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      ["https://shop.example\r\nx: y", "https://shop.example\n",
       "\nhttps://shop.example"].each do |origin|
        status, = build(api.origin).call(env_for("HTTP_ORIGIN" => origin))

        assert_equal 400, status, origin.inspect
      end

      assert_empty api.requests
    end
  end

  # ---- B: sdk platform -----------------------------------------------------

  BAD_PLATFORMS = [
    "IOS", "iOS", "ios\n", "\nios", "x\nios", "ios\nx", " ios", "ios ", "ios\t", "ios, android",
    "ios,ios", "ios, ios", "web", "browser", "", "ios\x00", "ios\r\n", "react-native-web"
  ].freeze

  GOOD_PLATFORMS = %w[
    ios android react-native react-native-ios react-native-android flutter flutter-ios
    flutter-android lynx-ios lynx-android capacitor kotlin-multiplatform
  ].freeze

  def test_invalid_platforms_without_origin_are_missing_origin
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      proxy = build(api.origin)
      BAD_PLATFORMS.each do |value|
        response = proxy.call(env_for("HTTP_ORIGIN" => nil,
                                      "HTTP_X_FINGERLY_SDK_PLATFORM" => value))

        assert_equal 400, response[0], value.inspect
        assert_includes body_of(response), "missing_origin", value.inspect
        assert_equal "no-store", response[1]["cache-control"]
      end

      assert_empty api.requests
    end
  end

  def test_invalid_platforms_with_origin_are_never_restored
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      proxy = build(api.origin)
      BAD_PLATFORMS.each do |value|
        proxy.call(env_for("HTTP_X_FINGERLY_SDK_PLATFORM" => value))
      end

      assert_equal BAD_PLATFORMS.size, api.requests.size
      api.requests.each { |seen| assert_nil seen.header("x-fingerly-sdk-platform") }
    end
  end

  def test_the_twelve_platforms_are_restored_and_origin_is_never_synthesized
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      proxy = build(api.origin)
      GOOD_PLATFORMS.each do |value|
        status, = proxy.call(env_for("HTTP_ORIGIN" => nil, "HTTP_X_FINGERLY_SDK_PLATFORM" => value,
                                     "HTTP_HOST" => "shop.example",
                                     "HTTP_REFERER" => "https://shop.example/x"))

        assert_equal 200, status, value
      end

      assert_equal(GOOD_PLATFORMS, api.requests.map { |r| r.header("x-fingerly-sdk-platform") })
      api.requests.each { |seen| assert_nil seen.header("x-fingerly-origin") }
    end
  end

  def test_no_origin_and_no_platform_is_missing_origin
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      ["", "   ", nil].each do |origin|
        response = build(api.origin).call(env_for("HTTP_ORIGIN" => origin,
                                                  "HTTP_HOST" => "shop.example"))

        assert_equal 400, response[0], origin.inspect
        assert_equal "no-store", response[1]["cache-control"]
      end

      assert_empty api.requests
    end
  end

  # ---- WEB-12: local public key check -------------------------------------

  def test_the_public_key_is_checked_locally
    bad = [nil, "", "nonsense", "fly_pk_staging_browser", "fly_pk_development_browser",
           "fly_sk_production_secret", PROXY_KEY, "fly_pk_production_browser\n",
           "x\nfly_pk_production_browser", "fly_pk_production_browser, fly_pk_production_browser",
           " fly_pk_production_browser", "fly_pk_production_", "FLY_PK_PRODUCTION_browser"]
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      proxy = build(api.origin)
      bad.each do |key|
        response = proxy.call(env_for("HTTP_X_API_KEY" => key))

        assert_equal 401, response[0], key.inspect
        assert_equal "no-store", response[1]["cache-control"]
      end

      assert_empty api.requests
    end
  end

  # ---- C: client IP --------------------------------------------------------

  BAD_IPS = [
    "", " ", "1.2.3.4/8", "1.2.3.4/32", "::1/128", "fe80::1%eth0", "fe80::1%25eth0", "[::1]",
    "1.2.3.4:80", "[::1]:80", " 1.2.3.4", "1.2.3.4 ", "1.2.3.4\n", "\n1.2.3.4", "1.2.3.4, 5.6.7.8",
    "1.2.3.4,5.6.7.8", "localhost", "example.com", "1.2.3", "1.2.3.4.", "1.2.3.4.5", "256.1.1.1",
    "01.2.3.4", "1.2.3.04", "0x1.2.3.4", "1:2:3:4:5:6:7:8:9", "00001::1", "::1::", ":::1",
    "1.2.3.4\x00", "16909060", "::ffff:1.2.3.4.5", "unknown", "::ffff:01.2.3.4"
  ].freeze

  def test_anything_but_one_ip_literal_is_a_500_without_an_upstream_call
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      (BAD_IPS + [nil, :sym, 16_909_060, IPAddr.new("1.2.3.4"), ["1.2.3.4"]]).each do |value|
        response = build(api.origin, client_ip: ->(_r) { value }).call(env_for)

        assert_equal 500, response[0], value.inspect
        assert_equal "no-store", response[1]["cache-control"]
        refute_includes body_of(response), value.to_s unless value.to_s.empty? || value.to_s == " "
      end

      assert_empty api.requests, lambda {
        api.requests.map { |r|
          r.header("x-fingerly-client-ip")
        }.inspect
      }
    end
  end

  def test_good_ip_literals_are_forwarded
    good = ["1.2.3.4", "::1", "2001:db8::1", "::ffff:1.2.3.4", "2001:DB8::1"]
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      good.each do |value|
        status, = build(api.origin, client_ip: ->(_r) { value }).call(env_for)

        assert_equal 200, status, value
      end

      assert_equal(good, api.requests.map { |r| r.header("x-fingerly-client-ip") })
    end
  end

  def test_there_is_no_default_client_ip
    assert_raises(ArgumentError) { Fingerly::Proxy.new(proxy_key: PROXY_KEY, path: PATH) }
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      # A callback that returns nothing must not fall back to anything the
      # visitor wrote or to the peer.
      response = build(api.origin, client_ip: ->(_r) {}).call(
        env_for("HTTP_X_FORWARDED_FOR" => "6.6.6.6", "HTTP_X_REAL_IP" => "6.6.6.6",
                "HTTP_X_FINGERLY_CLIENT_IP" => "6.6.6.6", "REMOTE_ADDR" => "6.6.6.6")
      )

      assert_equal 500, response[0]
      assert_empty api.requests
    end
  end

  # ---- D: path, method, target --------------------------------------------

  OTHER_PATHS = [
    "#{PATH}/", "#{PATH}//", "/#{PATH}", "#{PATH}/x", "#{PATH}/..", "#{PATH}/.", "/./k7x2qm4a",
    "/x/../k7x2qm4a", "/%6b7x2qm4a", "/k7x2qm4%61", "#{PATH}%2f", "#{PATH}%2F..", "#{PATH}%00",
    "/K7X2QM4A", "#{PATH};x=1", "#{PATH}.json", "#{PATH} ", "/", "", "#{PATH}\n", "x\n#{PATH}",
    "#{PATH}?x", "#{PATH}#x"
  ].freeze

  def test_only_the_exact_raw_path_is_answered
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      proxy = build(api.origin)
      OTHER_PATHS.each do |path|
        env = env_for
        env["PATH_INFO"] = path
        response = proxy.call(env)

        assert_equal 404, response[0], path.inspect
        assert_equal "no-store", response[1]["cache-control"], path.inspect
      end

      assert_empty api.requests
    end
  end

  def test_the_query_and_path_never_reach_the_upstream_target
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      env = env_for("#{PATH}?a=1&path=/api/v1/events", "HTTP_HOST" => "evil.example:9")
      env["REQUEST_URI"] = "http://evil.example#{PATH}?a=1"
      status, = build(api.origin).call(env)

      assert_equal 200, status
      assert_equal 1, api.requests.size
      assert_equal "/api/v1/ingest", api.requests.first.raw_uri
      assert_equal "POST", api.requests.first.request_method
    end
  end

  def test_the_api_version_cannot_carry_a_path
    ["v1/../x", "../", "v1/", "v1?x=1", "v1#x", "V1", "v0", "v01", "v1\n", "v1\n/x", "x\nv1", "",
     " v1", "v1 ", "v1%2f..", nil, 1, :v1].each do |version|
      assert_raises(Fingerly::ConfigurationError, version.inspect) do
        build("http://127.0.0.1:9", api_version: version)
      end
    end
  end

  def test_the_upstream_option_is_validated
    ["https://user:pass@127.0.0.1", "https://user@127.0.0.1", "https://127.0.0.1?x=1",
     "https://127.0.0.1#x", "ftp://127.0.0.1", "file:///etc/passwd", "//127.0.0.1", "127.0.0.1",
     "https://", "https:///x", "javascript:alert(1)", "https://127.0.0.1\n.evil.example",
     "x\nhttps://127.0.0.1", "https://127.0.0.1 x"].each do |upstream|
      assert_raises(Fingerly::ConfigurationError, upstream.inspect) { build(upstream) }
    end
  end

  # ---- E: body -------------------------------------------------------------

  def test_the_body_cap_holds_against_a_lying_content_length_and_no_length
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      proxy = build(api.origin)
      big = "a" * ((1 << 20) + 1)
      lying = env_for(body: big)
      lying["CONTENT_LENGTH"] = "2"
      chunked = env_for(body: big)
      chunked.delete("CONTENT_LENGTH")
      chunked["HTTP_TRANSFER_ENCODING"] = "chunked"
      negative = env_for(body: big)
      negative["CONTENT_LENGTH"] = "-1"

      [lying, chunked, negative].each do |env|
        response = proxy.call(env)

        assert_equal 413, response[0]
        assert_equal "no-store", response[1]["cache-control"]
      end

      assert_empty api.requests
      exact = env_for(body: "a" * (1 << 20))

      assert_equal 200, proxy.call(exact)[0]
    end
  end

  def test_the_body_is_forwarded_byte_for_byte
    raw = (0..255).map(&:chr).join.b + "\xff\xfe{\"a\": 1.0,  \"b\":1e3}\r\n\x00".b
    received = nil
    handler = lambda do |req, res|
      received = req.body.to_s.b
      res.status = 200
      res.body = "{}"
    end
    FakeAPI.run(handler) do |api|
      status, = build(api.origin).call(env_for(body: raw, "HTTP_CONTENT_ENCODING" => "gzip"))

      assert_equal 200, status
      assert_equal raw, received
      assert_equal raw.bytesize.to_s, api.requests.first.header("content-length")
      # Observation: the request content-encoding is not on the allowlist.
      assert_nil api.requests.first.header("content-encoding")
      assert_nil api.requests.first.header("transfer-encoding")
    end
  end

  # ---- E/F: response -------------------------------------------------------

  def test_a_decompression_bomb_is_a_bad_gateway
    bomb = Zlib.gzip("\0" * (64 << 20))
    handler = lambda do |_req, res|
      res.status = 200
      res["content-type"] = "application/json"
      res["content-encoding"] = "gzip"
      res.body = bomb
    end
    lines = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |line| lines << line }
    FakeAPI.run(handler) do |api|
      response = build(api.origin, logger: logger).call(env_for)

      assert_operator bomb.bytesize, :<, 1 << 20
      assert_equal 502, response[0]
      assert_equal "Bad gateway", body_of(response)
      assert_equal "no-store", response[1]["cache-control"]
      assert_equal 1, lines.size
      refute_includes lines.first, PROXY_KEY
    end
  end

  def test_an_oversized_plain_answer_is_a_bad_gateway
    handler = lambda do |_req, res|
      res.status = 200
      res.body = "a" * ((4 << 20) + 1)
    end

    FakeAPI.run(handler) do |api|
      assert_equal 502, build(api.origin).call(env_for)[0]
    end
    exact = lambda do |_req, res|
      res.status = 200
      res.body = "a" * (4 << 20)
    end

    FakeAPI.run(exact) do |api|
      assert_equal 200, build(api.origin).call(env_for)[0]
    end
  end

  def test_only_allowlisted_response_headers_are_relayed
    handler = lambda do |_req, res|
      res.status = 200
      res["content-type"] = "application/json"
      res["x-request-id"] = "req_1"
      res["ratelimit-limit"] = "10"
      res["ratelimit-remaining"] = "9"
      res["retry-after"] = "1"
      res["set-cookie"] = "a=b"
      res["server"] = "upstream"
      res["fingerly-balance-micros"] = "1"
      res["fingerly-ratelimit-scope"] = "x"
      res["cache-control"] = "public, max-age=600"
      res["access-control-allow-origin"] = "*"
      res["location"] = "https://elsewhere.example/"
      res["x-other"] = "y"
      res.body = "{}"
    end
    FakeAPI.run(handler) do |api|
      response = Rack::Lint.new(build(api.origin)).call(env_for("HTTP_ORIGIN" => "https://evil.example"))
      response[2].each { |_| nil }
      response[2].close if response[2].respond_to?(:close)

      assert_equal %w[cache-control content-type ratelimit-limit ratelimit-remaining
                      retry-after x-request-id], response[1].keys.sort
      assert_equal "no-store", response[1]["cache-control"]
    end
  end

  def test_a_redirect_is_never_followed_and_is_a_bad_gateway
    handler = lambda do |req, res|
      res.status = 307
      res["location"] = "http://#{req.host}:#{req.port}/elsewhere"
      res.body = ""
    end
    FakeAPI.run(handler) do |api|
      [301, 302, 303, 307, 308].each do |code|
        api.handler = lambda do |req, res|
          handler.call(req, res)
          res.status = code
        end
        response = build(api.origin).call(env_for)

        assert_equal 502, response[0], "upstream #{code}"
        assert_nil response[1]["location"]
        assert_equal "no-store", response[1]["cache-control"]
      end

      assert_equal 5, api.requests.size
      assert_equal ["/api/v1/ingest"], api.requests.map(&:raw_uri).uniq
    end
  end

  ODD_STATUSES = {
    "099" => "HTTP/1.1 099 Odd\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
    "101" => "HTTP/1.1 101 Switching Protocols\r\nconnection: close\r\n\r\n",
    "103" => "HTTP/1.1 103 Early Hints\r\nconnection: close\r\n\r\n",
    "199" => "HTTP/1.1 199 Odd\r\nconnection: close\r\n\r\n",
    "600" => "HTTP/1.1 600 Odd\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
    "999" => "HTTP/1.1 999 Odd\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
    "000" => "HTTP/1.1 000 Odd\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
    "304" => "HTTP/1.1 304 Not Modified\r\nconnection: close\r\n\r\n",
    "399" => "HTTP/1.1 399 Odd\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
  }.freeze

  ODD_STATUSES.each do |code, raw|
    define_method(:"test_an_upstream_status_#{code}_is_a_502") do
      RawServer.run(raw) do |server|
        response = build(server.origin).call(env_for)

        assert_equal 502, response[0], "upstream status #{code} was relayed as #{response[0]}"
        assert_equal "no-store", response[1]["cache-control"]
      end
    end
  end

  def test_every_local_answer_is_no_store # rubocop:disable Metrics/AbcSize
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      cors = build(api.origin, allowed_origins: ["https://app.example"])
      plain = build(api.origin)
      answers = {
        404 => plain.call(env_for("/other")),
        405 => plain.call(env_for(method: "GET")),
        401 => plain.call(env_for("HTTP_X_API_KEY" => nil)),
        400 => plain.call(env_for("HTTP_ORIGIN" => nil)),
        413 => plain.call(env_for(body: "a" * ((1 << 20) + 1))),
        500 => build(api.origin, client_ip: ->(_r) { "nope" }).call(env_for),
        204 => cors.call(env_for(method: "OPTIONS", "HTTP_ORIGIN" => "https://app.example")),
        403 => cors.call(env_for(method: "OPTIONS", "HTTP_ORIGIN" => "https://evil.example"))
      }
      answers.each do |expected, response|
        assert_equal expected, response[0]
        assert_equal "no-store", response[1]["cache-control"], expected.to_s
        assert_equal response[1].keys.map(&:downcase), response[1].keys, expected.to_s
        refute_match(/fingerly/i, body_of(response)) unless expected == 200
      end
      unreachable = build("http://127.0.0.1:1").call(env_for)

      assert_equal 502, unreachable[0]
      assert_equal "no-store", unreachable[1]["cache-control"]
    end
  end

  def test_cors_is_only_for_configured_origins
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      proxy = build(api.origin, allowed_origins: ["https://app.example", "*", "null"])
      ["https://evil.example", "https://app.example.evil.example", "https://APP.example",
       "https://app.example:443", "http://app.example", "https://app.example/",
       "https://app.example, https://evil.example"].each do |origin|
        %w[POST OPTIONS].each do |verb|
          response = proxy.call(env_for(method: verb, "HTTP_ORIGIN" => origin))

          assert_nil response[1]["access-control-allow-origin"], "#{verb} #{origin}"
        end
      end
      none = build(api.origin).call(env_for("HTTP_ORIGIN" => "https://app.example"))

      assert_nil none[1]["access-control-allow-origin"]
      ok = proxy.call(env_for("HTTP_ORIGIN" => "https://app.example"))

      assert_equal "https://app.example", ok[1]["access-control-allow-origin"]
      assert_equal "Origin", ok[1]["vary"]
    end
  end

  # ---- G: secrets ----------------------------------------------------------

  def test_the_key_is_in_no_rendering_of_the_proxy
    proxy = build("http://127.0.0.1:9")
    shown = [proxy.inspect, proxy.to_s, proxy.pretty_inspect, proxy.to_json, JSON.generate(proxy),
             JSON.generate([proxy]), YAML.dump(proxy), format("%<a>p %<b>s", a: proxy, b: proxy),
             proxy.as_json.to_s, [proxy].inspect, { p: proxy }.inspect]

    shown.each { |text| refute_includes text, "AUDITSECRETKEYVALUE", text[0, 80] }
    assert_raises(TypeError) { Marshal.dump(proxy) }
    assert_raises(TypeError) { Marshal.dump([proxy]) }
    transport = proxy.instance_variable_get(:@transport)

    refute_includes transport.inspect, "AUDITSECRETKEYVALUE"
  end

  def test_a_malformed_key_is_not_echoed_by_the_error
    ["fly_px_production_AUDITSECRETKEYVALUE\n", "fly_sk_production_AUDITSECRETKEYVALUE",
     "fly_px_prod_AUDITSECRETKEYVALUE", " fly_px_production_AUDITSECRETKEYVALUE"].each do |key|
      error = assert_raises(Fingerly::ConfigurationError) do
        Fingerly::Proxy.new(proxy_key: key, path: PATH, client_ip: ->(_r) { IP })
      end

      refute_includes error.message, "AUDITSECRETKEYVALUE"
      refute_includes error.full_message, "AUDITSECRETKEYVALUE"
    end
  end

  def test_failure_logs_and_bodies_name_neither_the_key_nor_the_upstream
    lines = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |line| lines << line }
    secret_body = "{\"upstream_secret_body\":true}"

    RawServer.run("HTTP/1.1 200 OK\r\ncontent-length: 500\r\n\r\n#{secret_body}") do |server|
      port = server.origin[/\d+\z/]
      cut = build(server.origin, logger: logger).call(env_for)
      refused = build("http://127.0.0.1:1", logger: logger).call(env_for)
      garbage = nil
      RawServer.run("garbage #{secret_body}\r\n\r\n") do |bad|
        garbage = build(bad.origin, logger: logger).call(env_for)
      end

      [cut, refused, garbage].each do |response|
        assert_equal 502, response[0]
        assert_equal "Bad gateway", body_of(response)
      end
      assert_equal 3, lines.size
      lines.each do |line|
        refute_includes line, "AUDITSECRETKEYVALUE"
        refute_includes line, "127.0.0.1"
        refute_includes line, port
        refute_includes line, "upstream_secret_body"
        refute_includes line, PUBLIC_KEY
      end
    end
  end

  # ---- H: deadline, retries ------------------------------------------------

  def test_a_failed_post_is_never_sent_twice
    server = CountingServer.new { |_client, _n| false } # read the request, hang up
    response = build(server.origin).call(env_for)

    assert_equal 502, response[0]
    sleep 0.2

    assert_equal 1, server.connections
    assert_equal 1, server.requests
  ensure
    server&.shutdown
  end

  def test_a_post_on_a_reused_connection_that_dies_is_not_resent
    server = CountingServer.new do |client, n|
      next false if n > 1 # the second request is read, then the socket is closed

      client.write("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" \
                   "content-length: 2\r\n\r\n{}")
      true
    end
    proxy = build(server.origin)

    assert_equal 200, proxy.call(env_for)[0]
    assert_equal 502, proxy.call(env_for)[0]
    sleep 0.2

    assert_equal 1, server.connections
    assert_equal 2, server.requests
  ensure
    server&.shutdown
  end

  def test_the_deadline_covers_a_dribbled_body
    server = CountingServer.new do |client, _n|
      client.write("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" \
                   "content-length: 100\r\n\r\n")
      100.times do
        client.write("a")
        sleep 0.2
      end
      false
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = build(server.origin, timeout: 1).call(env_for)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 504, response[0]
    assert_equal "Gateway timeout", body_of(response)
    assert_equal "no-store", response[1]["cache-control"]
    assert_operator elapsed, :<, 2.0
  ensure
    server&.shutdown
  end

  # ---- I: middleware -------------------------------------------------------

  def test_middleware_passes_other_paths_on_untouched_and_never_forwards_them
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      seen = nil
      app = lambda do |env|
        seen = [env["PATH_INFO"], env["rack.input"].read]
        [200, { "content-type" => "text/plain" }, ["app"]]
      end
      proxy = build(api.origin, app: app)
      status, = proxy.call(env_for("#{PATH}/x", body: "payload"))

      assert_equal 200, status
      assert_equal ["#{PATH}/x", "payload"], seen
      assert_empty api.requests
    end
    assert_raises(Fingerly::ConfigurationError) do
      build("http://127.0.0.1:9", app: ->(_e) { [200, {}, []] }, path: nil)
    end
  end
end
