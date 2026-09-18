# frozen_string_literal: true

require "test_helper"
require "digest"

# Every recorded response and delivery, read through the public API.
#
# These are the tests that would fail if the server changed a field name or a
# signing rule, rather than if this SDK changed its mind about one.
class ContractTest < Minitest::Test
  SECRET_KEY = "fly_sk_eu_production_contract"

  def test_snapshot_matches_its_manifest
    manifest = JSON.parse(File.read(File.join(Fixtures::DIR, "manifest.json")))
    files = manifest.fetch("files")

    refute_empty files
    files.each do |name, expected|
      actual = Digest::SHA256.hexdigest(File.binread(File.join(Fixtures::DIR, name)))

      assert_equal expected, actual, "#{name} is stale"
    end
  end

  def test_reads_every_event_fixture
    fixtures = Fixtures.responses("SDKEventOut")

    refute_empty fixtures
    fixtures.each do |fixture|
      body = JSON.generate(fixture.fetch("body"))
      FakeAPI.run(FakeAPI.json(fixture.fetch("status"), body)) do |api|
        event = client(api).events.get("id")
        want = fixture.fetch("body")

        assert_equal want["request_id"], event.request_id, fixture["name"]
        assert_equal want["visitor_id"], event.visitor_id, fixture["name"]
        assert_kind_of Time, event.occurred_at

        # A fixture without a score must not decode as zero.
        if want["suspect_score"].nil?
          refute_predicate event, :scored?, "#{fixture["name"]} decoded as scored"
          assert_nil event.suspect_score
        else
          assert_predicate event, :scored?
          assert_equal want["suspect_score"], event.suspect_score, fixture["name"]
        end
      end
    end
  end

  def test_reads_every_page_fixture
    fixtures = Fixtures.responses("SDKEventsOut")

    refute_empty fixtures
    fixtures.each do |fixture|
      body = JSON.generate(fixture.fetch("body"))
      FakeAPI.run(FakeAPI.json(fixture.fetch("status"), body)) do |api|
        page = client(api).events.list
        want = fixture.fetch("body")

        assert_equal want["page"], page.page, fixture["name"]
        assert_equal want["page_size"], page.page_size, fixture["name"]
        assert_equal want.fetch("rows").map { |row| row["request_id"] }, page.map(&:request_id)
      end
    end
  end

  def test_maps_every_error_fixture
    fixtures = Fixtures.responses("ErrorResponse")

    refute_empty fixtures
    fixtures.each do |fixture|
      body = JSON.generate(fixture.fetch("body"))
      FakeAPI.run(FakeAPI.json(fixture.fetch("status"), body)) do |api|
        error = assert_raises(Fingerly::APIError, fixture["name"]) do
          client(api).events.get("id")
        end
        want = fixture.fetch("body")

        assert_equal fixture.fetch("status"), error.status, fixture["name"]
        assert_equal want.dig("error", "code"), error.code, fixture["name"]
        assert_equal want["request_id"], error.request_id, fixture["name"]
      end
    end
  end

  def test_verifies_every_webhook_fixture
    fixtures = Fixtures.webhooks

    refute_empty fixtures
    fixtures.each do |fixture|
      # Each is verified at the instant it was signed.
      signed_at = Time.at(Integer(fixture.fetch("timestamp"), 10))
      verified = Fingerly::Webhooks.verify(
        secret: fixture.fetch("secret"),
        payload: fixture.fetch("payload"),
        timestamp: fixture.fetch("timestamp"),
        signature: fixture.fetch("signature"),
        now: signed_at
      )

      assert_equal fixture.fetch("valid"), verified, fixture["name"]
    end
  end

  def test_refuses_a_recorded_delivery_past_the_replay_window
    stale = Fixtures.webhooks.first
    signed_at = Time.at(Integer(stale.fetch("timestamp"), 10))

    refute Fingerly::Webhooks.verify(
      secret: stale.fetch("secret"),
      payload: stale.fetch("payload"),
      timestamp: stale.fetch("timestamp"),
      signature: stale.fetch("signature"),
      now: signed_at + 301
    )
  end

  def test_parses_the_recorded_webhook_envelope
    delivery = Fingerly::Webhooks.parse(Fixtures.webhooks.first.fetch("payload"))

    refute_nil delivery.id
    refute_nil delivery.type
    # Data stays raw, so a new event type needs no SDK upgrade.
    assert_kind_of Hash, delivery.data
    refute_nil delivery.data["request_id"]
  end

  private

  def client(api)
    Fingerly::Client.new(secret_key: SECRET_KEY, endpoint: api.origin)
  end
end
