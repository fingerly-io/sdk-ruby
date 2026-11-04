# frozen_string_literal: true

require "test_helper"
require "pp"
require "yaml"

# A credential must not come back out of any way Ruby shows or saves an
# object: inspect, to_s, pp, JSON, YAML or Marshal. A client in a console, a
# proxy printed by a debugging session, or an error tracker recording locals
# would otherwise put a secret key in a log.
class RedactionTest < Minitest::Test
  SECRET_KEY = "fly_sk_production_secretvalue123"
  PROXY_KEY = "fly_px_production_proxyvalue456"
  COOKIE = "session=visitorcookie789"

  def test_the_client_never_shows_its_secret_key
    client = Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: "http://127.0.0.1:9")

    assert_hidden(client, SECRET_KEY)
    assert_hidden(client.events, SECRET_KEY)
    assert_includes client.inspect, "[redacted]"
  end

  def test_the_proxy_never_shows_its_key
    proxy = Fingerly::Proxy.new(proxy_key: PROXY_KEY, path: "/k7x2qm4a",
                                client_ip: ->(_r) { "203.0.113.7" })
    legacy = Fingerly::Proxy.new(secret_key: SECRET_KEY, path: "/k7x2qm4a",
                                 client_ip: ->(_r) { "203.0.113.7" })

    assert_hidden(proxy, PROXY_KEY)
    assert_hidden(legacy, SECRET_KEY)
    assert_includes proxy.inspect, "[redacted]"
  end

  def test_the_request_given_to_client_ip_never_shows_the_visitors_cookies
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/k7x2qm4a", "REMOTE_ADDR" => "10.0.0.1",
            "HTTP_COOKIE" => COOKIE, "HTTP_AUTHORIZATION" => "Bearer #{COOKIE}" }
    request = Fingerly::ProxyRequest.new(env, "/k7x2qm4a")

    assert_hidden(request, COOKIE)
    assert_equal COOKIE, request.header("cookie"), "the callback can still read it"
  end

  def test_marshal_refuses_rather_than_writing_the_key
    client = Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: "http://127.0.0.1:9")

    assert_raises(TypeError) { Marshal.dump(client) }
  end

  private

  def assert_hidden(object, secret)
    shown = {
      "inspect" => object.inspect,
      "to_s" => object.to_s,
      "interpolation" => "#{object}", # rubocop:disable Style/RedundantInterpolation
      "pp" => object.pretty_inspect,
      "as_json" => object.as_json.to_s,
      "to_json" => object.to_json,
      "JSON.generate" => JSON.generate([object]),
      "YAML" => YAML.dump(object)
    }

    shown.each do |via, text|
      refute_includes text, secret, "#{object.class} leaked a credential through #{via}"
    end
  end
end
