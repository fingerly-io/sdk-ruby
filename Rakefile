# frozen_string_literal: true

require "rake/testtask"
require "rubocop/rake_task"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  # Ruby's own warnings catch what RuboCop does not: a shadowed variable, a
  # method redefined, a constant reassigned.
  t.warning = true
end

RuboCop::RakeTask.new

desc "Check the RBS signatures against the library"
task :signatures do
  sh "bundle exec rbs --log-level=error -I sig validate"
end

# release.yml runs this. Bundler's stock task tags before it uploads,
# so a rejected upload would leave a tag that stops every retry. release.yml
# tags after the upload instead.
desc "Build the gem into pkg/ and push it to RubyGems"
task :release do
  require_relative "lib/fingerly/version"
  gem_file = "pkg/fingerly-#{Fingerly::VERSION}.gem"
  mkdir_p "pkg"
  sh "gem build fingerly.gemspec --output #{gem_file}"
  sh "gem push #{gem_file}"
end

task default: %i[test rubocop signatures]
