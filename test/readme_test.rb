# frozen_string_literal: true

require "test_helper"

# The README is pasted into applications, so its snippets have to be code
# that runs, and its promises have to match the gem.
class ReadmeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  README = File.read(File.join(ROOT, "README.md"))

  def test_every_ruby_snippet_compiles
    blocks = README.scan(/```ruby\n(.*?)```/m).flatten

    refute_empty blocks
    blocks.each do |code|
      RubyVM::InstructionSequence.compile(code)
    rescue SyntaxError => e
      flunk "README snippet does not compile: #{e.message}\n#{code}"
    end
  end

  # `use` appends the proxy after Rails' own middleware, which rewrites its
  # answers on the way out.
  def test_the_rails_example_puts_the_proxy_first
    assert_includes README, "config.middleware.insert_before 0, Fingerly::Proxy"
    refute_includes README, "config.middleware.use Fingerly::Proxy"
  end

  def test_the_ruby_floor_matches_the_gemspec
    spec = Gem::Specification.load(File.join(ROOT, "fingerly.gemspec"))

    assert_equal Gem::Requirement.new(">= 3.2.0"), spec.required_ruby_version
    assert_includes README, "Ruby 3.2+"
  end

  # The fiber-scheduler promise rests on the same floor; naming an older Ruby
  # for it would contradict the line above.
  def test_the_readme_names_no_ruby_below_the_floor
    refute_match(/Ruby 3\.[01]\b|\b3\.[01]\+?\s/, README)
  end

  def test_the_versions_agree
    changelog = File.read(File.join(ROOT, "CHANGELOG.md"))

    assert_equal Fingerly::VERSION, changelog[/^## (\d+\.\d+\.\d+)/, 1]
    assert_equal "ruby/#{Fingerly::VERSION}", Fingerly::Proxy::PROXY_VERSION
    assert_includes README, "`ruby/#{Fingerly::VERSION}`"
  end
end
