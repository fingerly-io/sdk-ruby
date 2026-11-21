# frozen_string_literal: true

require "sightings_helper"
require "rack"
require "rack/lint"

# Records what the middleware reports instead of buffering it.
class RecordingSightings < Fingerly::AgentSightings
  def reported
    @reported ||= []
  end

  def report(request)
    reported << request["PATH_INFO"]
    nil
  end
end

class AgentSightingsMiddlewareTest < Minitest::Test
  include SightingsHelpers

  def test_reports_html_whatever_the_status
    [200, 404, 500].each do |code|
      assert_equal ["/page"], reported("/page", code, "text/html; charset=utf-8"), code.to_s
    end
    assert_equal ["/page"], reported("/page", 200, "application/xhtml+xml")
    assert_equal ["/page"], reported("/page", 200, "Text/HTML;charset=UTF-8")
  end

  def test_leaves_out_assets_and_api_answers
    ["application/json", "image/png", "text/css", "application/javascript", nil].each do |type|
      assert_empty reported("/page", 200, type), type.inspect
    end
  end

  def test_reports_the_well_known_paths_whatever_they_answer
    %w[/robots.txt /llms.txt /llms-full.txt].each do |path|
      assert_equal [path], reported(path, 200, "text/plain")
      assert_equal [path], reported(path, 404, nil)
    end
    assert_empty reported("/robots.txt/x", 200, "text/plain")
  end

  def test_include_prefixes_widen_and_exclude_prefixes_win
    options = { include_path_prefixes: ["/api/"], exclude_path_prefixes: ["/admin", "/llms"] }

    assert_equal ["/api/v1"], reported("/api/v1", 200, "application/json", **options)
    assert_empty reported("/admin/users", 200, "text/html", **options)
    assert_empty reported("/llms.txt", 200, "text/plain", **options)
    assert_equal ["/robots.txt"], reported("/robots.txt", 200, "text/plain", **options)
  end

  def test_content_types_replace_the_default
    options = { content_types: ["application/json"] }

    assert_equal ["/x"], reported("/x", 200, "application/json; charset=utf-8", **options)
    assert_empty reported("/x", 200, "text/html", **options)
  end

  def test_reads_a_rack_2_header_name
    assert_equal ["/page"], reported("/page", 200, nil, headers: { "Content-Type" => "text/html" })
  end

  # Only the customer's response decides; who claims to be asking never does.
  def test_never_filters_by_user_agent
    sightings = recording
    app = middleware(sightings, 200, "text/html")
    [GPTBOT, "Mozilla/5.0 (Macintosh)", "", nil].each { |agent| app.call(env(user_agent: agent)) }

    assert_equal 4, sightings.reported.size
  end

  def test_returns_the_application_response_untouched_under_rack_lint
    body = ["<html></html>"]
    inner = lambda do |_env|
      [200, { "content-type" => "text/html", "content-length" => body.first.bytesize.to_s }, body]
    end
    sightings = recording
    app = Rack::Lint.new(
      Fingerly::AgentSightings::Middleware.new(Rack::Lint.new(inner), sightings)
    )
    request = Rack::MockRequest.env_for("/page", "REMOTE_ADDR" => "203.0.113.7")
    status, headers, response = app.call(request)
    # A Lint body answers each, and nothing else may be assumed of it.
    chunks = response.to_enum(:each).to_a
    response.close

    assert_equal 200, status
    assert_equal "text/html", headers["content-type"]
    assert_equal body, chunks
    assert_equal ["/page"], sightings.reported
  end

  def test_a_failing_report_never_fails_the_response
    sightings = recording
    def sightings.report(_request) = raise("broken")
    status, = middleware(sightings, 200, "text/html").call(env)

    assert_equal 200, status
  end

  def test_an_application_error_is_the_applications
    app = Fingerly::AgentSightings::Middleware.new(->(_env) { raise IOError, "app" }, recording)

    assert_raises(IOError) { app.call(env) }
  end

  def test_reporting_never_delays_the_response
    release = Queue.new
    handler = lambda do |req, res|
      release.pop
      answering.call(req, res)
    end
    FakeAPI.run(handler) do |api|
      sightings = sightings(api)
      app = middleware(sightings, 200, "text/html")
      slowest = 0
      # Crosses the 200-item threshold, so a flush is in flight against an API
      # that does not answer while the rest are served.
      400.times do |i|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        app.call(env(user_agent: "ua-#{i}"))
        slowest = [slowest, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started].max
      end

      assert(eventually? { api.requests.size == 1 })
      assert_operator slowest, :<, 0.05
      2.times { release << true }
    end
  end

  def test_reports_through_to_the_api
    FakeAPI.run(answering) do |api|
      sightings = sightings(api)
      app = middleware(sightings, 200, "text/html")
      app.call(env)
      middleware(sightings, 200, "application/json").call(env(user_agent: "json"))
      sightings.flush

      assert_equal([GPTBOT], items_of(api.requests.first).map { |item| item["user_agent"] })
      refute_same Fingerly::AgentSightings::UNKNOWN, sightings.lookup(env)
    end
  end

  def test_refuses_options_of_the_wrong_shape
    sightings = recording

    [
      { content_types: "text/html" }, { content_types: [""] },
      { include_path_prefixes: ["api"] }, { exclude_path_prefixes: [nil] }
    ].each do |options|
      assert_raises(Fingerly::ConfigurationError, options.inspect) do
        Fingerly::AgentSightings::Middleware.new(->(_env) {}, sightings, **options)
      end
    end
    assert_raises(Fingerly::ConfigurationError) do
      Fingerly::AgentSightings::Middleware.new(->(_env) {}, Object.new)
    end
  end

  private

  def recording
    made = RecordingSightings.new(secret_key: SECRET_KEY, client_ip: lambda(&:peer_host))
    @made << made
    made
  end

  def middleware(sightings, code, type, headers: nil, **)
    response_headers = headers || (type ? { "content-type" => type } : {})
    Fingerly::AgentSightings::Middleware.new(->(_env) { [code, response_headers, []] }, sightings,
                                             **)
  end

  def reported(path, code, type, headers: nil, **)
    sightings = recording
    middleware(sightings, code, type, headers: headers, **)
      .call(env.merge("PATH_INFO" => path))
    sightings.reported
  end
end
