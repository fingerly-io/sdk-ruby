# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development do
  gem "async", "~> 2.23" # proves the client needs no asynchronous twin
  gem "minitest", "~> 5.25"
  gem "rack", "~> 3.1"        # Rack::Lint holds the proxy to the spec
  gem "rake", "~> 13.2"
  gem "rbs", "~> 3.8"
  gem "rubocop", "~> 1.68"
  gem "rubocop-minitest", "~> 0.36"
  gem "webrick", "~> 1.9"     # a real HTTP server for the fake API
end
