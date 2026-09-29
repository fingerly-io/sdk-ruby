# frozen_string_literal: true

require_relative "lib/fingerly/version"

Gem::Specification.new do |spec|
  spec.name = "fingerly"
  spec.version = Fingerly::VERSION
  spec.authors = ["Fingerly"]
  spec.email = ["support@fingerly.io"]

  spec.summary =
    "Server-side Fingerly SDK: event reads, webhook verification and a same-origin proxy"
  spec.description = <<~TEXT
    Reads stored identification events with a secret key, verifies signed
    webhooks, and forwards the browser SDK's requests through a route on your
    own domain as Rack middleware. No runtime dependencies.
  TEXT
  spec.homepage = "https://docs.fingerly.io/docs/sdks/ruby"

  # Ruby 3.2 is the floor the docs promise. Every newer release is tested too.
  #
  # It is 3.2 rather than 3.1 because of the claim this gem is built on: one
  # synchronous client is enough, since Net::HTTP yields to a fiber scheduler.
  # `test/concurrency_test.rb` is the proof of that, and on 3.1 it does not
  # hold — the scheduled calls never reach the server at all. A floor is a
  # promise about behaviour, not a minimum that happens to parse, so it stops
  # where the proof stops. 3.1 has been end-of-life since March 2025.
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata = {
    "documentation_uri" => "https://docs.fingerly.io/docs/sdks/ruby",
    "source_code_uri" => "https://github.com/fingerly-io/sdk-ruby",
    "rubygems_mfa_required" => "true",
    # Nothing here is published yet, and a private SDK reaching a public
    # registry is not a mistake anybody can take back.
    "allowed_push_host" => "https://rubygems.invalid"
  }

  spec.license = "Apache-2.0"
  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  # Everything it needs is in the standard library: net/http, json, openssl
  # and uri. Rack is a contract, not a dependency: the proxy speaks it without
  # loading it, so it cannot pin a version against the application's own.
end
