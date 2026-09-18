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

task default: %i[test rubocop signatures]
