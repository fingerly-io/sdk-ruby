# frozen_string_literal: true

# Refreshes the vendored server contract snapshot.
#
# The snapshot keeps the test suite independent of sibling repositories. Point
# FINGERLY_CONTRACT_DIR at the integration workspace's contract directory to
# pull a newer one:
#
#     FINGERLY_CONTRACT_DIR=../../contract ruby tools/sync_contract.rb
#
# A plain script, run straight from source, so refreshing the snapshot needs no
# build step. ContractTest verifies the result, so there is no separate check
# mode: `rake test` is the check.

require "digest"
require "fileutils"
require "json"
require "pathname"

FILES = %w[openapi.json fixtures.json].freeze

source = Pathname(ENV.fetch("FINGERLY_CONTRACT_DIR", "contract"))
# The repository root is wherever the gemspec is, so the script writes to the
# same place whichever directory it was launched from.
target = Pathname(__dir__).parent.join("contract")

manifest = source.join("manifest.json").binread
hashes = JSON.parse(manifest).fetch("files")

# Copy only after every file matches the hash the server recorded, so a
# half-written snapshot cannot land.
staged = { "manifest.json" => manifest }
FILES.each do |name|
  content = source.join(name).binread
  actual = Digest::SHA256.hexdigest(content)
  expected = hashes.fetch(name)
  raise "Invalid contract hash for #{name}: #{actual}" unless actual == expected

  staged[name] = content
end

FileUtils.mkdir_p(target)
staged.each { |name, content| target.join(name).binwrite(content) }
puts "Ruby contract snapshot refreshed into #{target}."
