# frozen_string_literal: true

require "test_helper"

# A clock the test moves by hand. Answers expire and pending reports age by
# it; the background thread still wakes on real time.
class FakeClock
  def initialize
    @now = 1000.0
    @lock = Mutex.new
  end

  def call = @lock.synchronize { @now }

  def advance(seconds)
    @lock.synchronize { @now += seconds }
  end
end

# Collects log lines.
class LineLogger
  attr_reader :lines

  def initialize
    @lines = []
  end

  def warn(line)
    @lines << line
  end
end

# What the agent sightings tests share: an instance per test, closed after
# it, a Rack environment builder and canned API answers.
module SightingsHelpers
  SECRET_KEY = "fly_sk_production_sightings"
  GPTBOT = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; GPTBot/1.4"

  def setup
    @made = []
    @clock = FakeClock.new
    @logger = LineLogger.new
  end

  def teardown
    @made.each(&:close)
  end

  def sightings(api, **)
    endpoint = api.respond_to?(:origin) ? api.origin : api
    made = Fingerly::AgentSightings.new(
      secret_key: SECRET_KEY, endpoint: endpoint, allow_insecure_loopback: true,
      client_ip: lambda(&:peer_host), clock: @clock, logger: @logger, **
    )
    @made << made
    made
  end

  def env(user_agent: GPTBOT, ip: "203.0.113.7", **headers)
    base = {
      "REQUEST_METHOD" => "GET", "PATH_INFO" => "/page", "QUERY_STRING" => "q=secret",
      "REMOTE_ADDR" => ip, "HTTP_HOST" => "example.com",
      "HTTP_COOKIE" => "session=secret", "HTTP_AUTHORIZATION" => "Bearer secret"
    }
    base["HTTP_USER_AGENT"] = user_agent if user_agent
    headers.each { |name, value| base["HTTP_#{name.to_s.upcase}"] = value }
    base
  end

  def signed_env(**)
    env(signature: "sig1=:abc:", signature_input: 'sig1=("@authority")',
        signature_agent: '"https://chatgpt.com"', **)
  end

  # Answers every item with the same answer.
  def answering(ttl: 60, rules: "r1", kind: Fingerly::VisitorKind::AI_BOT, agent: "GPTBot")
    lambda do |req, res|
      items = JSON.parse(req.body).fetch("items")
      res.status = 200
      res["content-type"] = "application/json"
      res.body = JSON.generate(
        "rules_version" => rules,
        "items" => items.map { { "ttl" => ttl, "visitor_kind" => kind, "agent" => agent } }
      )
    end
  end

  def status(code, headers = {})
    lambda do |_req, res|
      res.status = code
      headers.each { |name, value| res[name] = value }
      res["content-type"] = "application/json"
      res.body = '{"error":{"code":"refused"}}'
    end
  end

  def items_of(request)
    JSON.parse(request.body).fetch("items")
  end

  def eventually?(seconds = 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
    true
  end
end
