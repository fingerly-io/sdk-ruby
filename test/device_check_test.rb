# frozen_string_literal: true

require "test_helper"

# The DeviceCheck spend routes: one read or one write per held token, and a
# retry only with the same request.
class DeviceCheckTest < Minitest::Test
  SECRET_KEY = "fly_sk_staging_abc123"
  REQUEST_ID = "01a1e665-198c-760c-abf9-3666cb1c8e85"
  BITS = '{"found":true,"bit0":true,"bit1":false,"last_update":"2026-10"}'

  def test_query_posts_with_no_body_and_reads_the_bits
    FakeAPI.run(FakeAPI.json(200, BITS)) do |api|
      bits = client(api).device_check.query(REQUEST_ID)

      assert_predicate bits, :found?
      assert bits.bit0
      refute bits.bit1
      assert_equal "2026-10", bits.last_update

      request = api.requests.first

      assert_equal "POST", request.request_method
      assert_equal "/api/v1/events/#{REQUEST_ID}/device-check/query", request.raw_uri
      assert_equal SECRET_KEY, request.header("x-api-key")
      assert_equal "", request.body
      assert_equal "0", request.header("content-length")
    end
  end

  def test_query_without_bits_has_no_last_update
    FakeAPI.run(FakeAPI.json(200, '{"found":false,"bit0":false,"bit1":false}')) do |api|
      bits = client(api).device_check.query(REQUEST_ID)

      refute bits.found
      assert_nil bits.last_update
    end
  end

  def test_write_puts_only_the_bits_named
    FakeAPI.run(FakeAPI.json(200, '{"bit1":true}')) do |api|
      written = client(api).device_check.write(REQUEST_ID, bit1: true)

      assert written.bit1
      assert_nil written.bit0

      request = api.requests.first

      assert_equal "PUT", request.request_method
      assert_equal "/api/v1/events/#{REQUEST_ID}/device-check", request.raw_uri
      assert_equal({ "bit1" => true }, JSON.parse(request.body))
      assert_equal "application/json", request.header("content-type")
    end
  end

  def test_write_sends_false_as_a_value
    FakeAPI.run(FakeAPI.json(200, '{"bit0":false,"bit1":true}')) do |api|
      written = client(api).device_check.write(REQUEST_ID, bit0: false, bit1: true)

      refute_nil written.bit0
      refute written.bit0
      assert_equal({ "bit0" => false, "bit1" => true }, JSON.parse(api.requests.first.body))
    end
  end

  def test_write_with_no_bit_sends_nothing
    FakeAPI.run(FakeAPI.json(200, "{}")) do |api|
      assert_raises(Fingerly::ConfigurationError) { client(api).device_check.write(REQUEST_ID) }
      assert_raises(Fingerly::ConfigurationError) { client(api).device_check.write(REQUEST_ID, bit0: "yes") }
      assert_empty api.requests
    end
  end

  def test_a_request_id_stays_in_its_segment
    FakeAPI.run(FakeAPI.json(200, BITS)) do |api|
      client(api).device_check.query("a/../b")

      assert_equal "/api/v1/events/a%2F..%2Fb/device-check/query", api.requests.first.raw_uri
      assert_raises(Fingerly::ConfigurationError) { client(api).device_check.query("..") }
    end
  end

  def test_every_code_has_its_predicate
    {
      [404, "device_check_not_held"] => :not_held?,
      [409, "device_check_spent"] => :spent?,
      [409, "device_check_busy"] => :busy?,
      [409, "credential_unavailable"] => :credential_unavailable?,
      [422, "bits_required"] => :bits_required?,
      [422, "apple_rejected"] => :apple_rejected?
    }.each do |(status, code), predicate|
      FakeAPI.run(FakeAPI.json(status, error(code))) do |api|
        error = assert_raises(Fingerly::DeviceCheckError) { client(api).device_check.query(REQUEST_ID) }

        assert_kind_of Fingerly::APIError, error
        assert_equal status, error.status
        assert_equal code, error.code
        assert error.public_send(predicate), "#{code} should answer #{predicate}"
        assert_equal 1, api.requests.size, "#{status} #{code} must not be retried"
      end
    end
  end

  def test_apple_rejected_carries_apples_status
    detail = { "field" => "apple_status", "location" => "upstream", "issue" => "400" }
    body = JSON.generate("error" => { "code" => "apple_rejected", "message" => "rejected",
                                      "status" => 422, "details" => [detail] })
    FakeAPI.run(FakeAPI.json(422, body)) do |api|
      error = assert_raises(Fingerly::DeviceCheckError) { client(api).device_check.write(REQUEST_ID, bit0: true) }

      assert_predicate error, :apple_rejected?
      assert_equal 400, error.apple_status
    end
    FakeAPI.run(FakeAPI.json(409, error("device_check_spent"))) do |api|
      error = assert_raises(Fingerly::DeviceCheckError) { client(api).device_check.query(REQUEST_ID) }

      assert_nil error.apple_status
    end
  end

  def test_a_503_is_retried_with_the_same_request
    answers = [503, 503, 200]
    handler = lambda do |_req, res|
      status = answers.shift
      res.status = status
      res["content-type"] = "application/json"
      res["retry-after"] = "0"
      res.body = status == 200 ? '{"bit0":true}' : error("device_check_unavailable")
    end
    FakeAPI.run(handler) do |api|
      written = client(api).device_check.write(REQUEST_ID, bit0: true)

      assert written.bit0
      assert_equal 3, api.requests.size
      assert_equal 1, api.requests.map { |r| [r.request_method, r.raw_uri, r.body] }.uniq.size
    end
  end

  def test_a_503_that_persists_raises_unavailable
    handler = lambda do |_req, res|
      res.status = 503
      res["content-type"] = "application/json"
      res["retry-after"] = "0"
      res.body = error("device_check_unavailable")
    end
    FakeAPI.run(handler) do |api|
      error = assert_raises(Fingerly::DeviceCheckError) { client(api).device_check.query(REQUEST_ID) }

      assert_predicate error, :unavailable?
      assert_equal Fingerly::Client::DEVICE_CHECK_ATTEMPTS, api.requests.size
    end
  end

  def test_other_failures_are_not_retried
    [[429, "rate_limited"], [500, "internal"]].each do |status, code|
      FakeAPI.run(FakeAPI.json(status, error(code))) do |api|
        assert_raises(Fingerly::DeviceCheckError) { client(api).device_check.write(REQUEST_ID, bit0: true) }
        assert_equal 1, api.requests.size, "#{status} must not be retried"
      end
    end
  end

  def test_a_connection_failure_is_retried_then_raised
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    accepted = 0
    thread = Thread.new do
      loop do
        socket = server.accept
        accepted += 1
        socket.close
      end
    rescue IOError
      # Closed below.
    end
    fingerly = Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: "http://127.0.0.1:#{port}",
                                    allow_insecure_loopback: true)

    assert_raises(Fingerly::ConnectionError) { fingerly.device_check.write(REQUEST_ID, bit0: true) }
    assert_equal Fingerly::Client::DEVICE_CHECK_ATTEMPTS, accepted
  ensure
    server&.close
    thread&.join(1)
  end

  private

  def error(code)
    JSON.generate("error" => { "code" => code, "message" => code, "status" => 0 })
  end

  def client(api)
    Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: api.origin,
                         allow_insecure_loopback: true)
  end
end
