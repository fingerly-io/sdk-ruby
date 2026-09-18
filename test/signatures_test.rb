# frozen_string_literal: true

require "test_helper"
require "rbs"
require "pathname"

# The signatures have to describe the library that exists.
#
# `rbs validate` only proves the signatures are consistent with each other. A
# reader added by metaprogramming, a method renamed, or a constant removed
# would all pass it and leave sig/fingerly.rbs quietly wrong, so every name it
# declares is looked up on the real object here.
class SignaturesTest < Minitest::Test
  SIG_DIR = Pathname(File.expand_path("../sig", __dir__))

  # Config, Models and Transport are marked @api private; they are
  # implementation detail rather than a surface anyone should type against.
  INTERNAL = %w[Fingerly::Config Fingerly::Models Fingerly::Transport].freeze

  def test_every_declared_name_exists
    missing = []

    environment.class_decls.each do |type_name, entry|
      target = resolve(type_name)
      next if target.nil?

      declared_members(entry).each do |member|
        missing.concat(check(target, member))
      end
    end

    assert_empty missing, "sig/fingerly.rbs declares names the library does not have"
  end

  def test_every_public_class_is_declared
    declared = environment.class_decls.keys.map { |name| name.to_s.delete_prefix("::") }
    public_types = Fingerly.constants.filter_map do |name|
      value = Fingerly.const_get(name)
      "Fingerly::#{name}" if value.is_a?(Module) && !internal?(value)
    end

    assert_empty public_types - declared, "undeclared public types"
  end

  private

  def internal?(value)
    INTERNAL.include?(value.name)
  end

  def environment
    @environment ||= begin
      loader = RBS::EnvironmentLoader.new(core_root: nil)
      loader.add(path: SIG_DIR)
      RBS::Environment.from_loader(loader).resolve_type_names
    end
  end

  def resolve(type_name)
    Object.const_get(type_name.to_s.delete_prefix("::"))
  rescue NameError
    flunk "sig declares #{type_name}, which does not exist"
  end

  def declared_members(entry)
    entry.decls.flat_map { |declaration| declaration.decl.members }
  end

  def check(target, member)
    case member
    when RBS::AST::Members::MethodDefinition then check_method(target, member)
    when RBS::AST::Members::AttrReader then check_attr(target, member)
    when RBS::AST::Declarations::Constant then check_constant(target, member)
    else []
    end
  end

  def check_method(target, member)
    name = member.name
    return [] if name == :initialize

    # module_function puts the callable copy on the singleton and leaves the
    # instance copy private, so both are acceptable evidence.
    holder = member.singleton? ? target.singleton_class : target
    return [] if holder.method_defined?(name) || holder.private_method_defined?(name)

    ["#{target}##{name}"]
  end

  def check_attr(target, member)
    return [] if target.method_defined?(member.name)

    ["#{target}##{member.name}"]
  end

  def check_constant(target, member)
    name = member.name.name
    return [] if target.const_defined?(name, false)

    ["#{target}::#{name}"]
  end
end
