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

  # Ruby 3.1 is the floor the docs promise. Every newer release is tested too.
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata = {
    "documentation_uri" => "https://docs.fingerly.io/docs/sdks/ruby",
    "source_code_uri" => "https://github.com/fingerly-io/sdk-ruby",
    "rubygems_mfa_required" => "true",
    # Nothing here is published yet, and a private SDK reaching a public
    # registry is not a mistake anybody can take back.
    "allowed_push_host" => "https://rubygems.invalid"
  }

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "README.md"]
  spec.require_paths = ["lib"]

  # Everything it needs is in the standard library: net/http, json, openssl
  # and uri. Rack is a contract, not a dependency: the proxy speaks it without
  # loading it, so it cannot pin a version against the application's own.
end
