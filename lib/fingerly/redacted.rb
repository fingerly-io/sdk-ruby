# frozen_string_literal: true

module Fingerly
  # Keeps credentials out of every way Ruby has of showing or saving an object.
  #
  # The default +inspect+ lists instance variables, so a client in a console,
  # a +pp+ in a log line, or an error tracker that records locals would print
  # its secret key. ActiveSupport's +as_json+ does the same through
  # +instance_values+, and Marshal and YAML would write it to disk. Each class
  # that holds a credential, or a visitor's cookies, includes this and names
  # only what is safe to show.
  #
  # @api private
  module Redacted
    # What replaces a credential wherever one would have been shown.
    MARK = "[redacted]"

    def inspect
      fields = redacted_fields.map { |name, value| "#{name}=#{value}" }
      "#{["#<#{self.class.name}", *fields].join(" ")}>"
    end

    def to_s
      inspect
    end

    def pretty_print(printer)
      printer.text(inspect)
    end

    def as_json(*)
      inspect
    end

    def to_json(*)
      inspect.to_json(*)
    end

    # YAML: the object is written as its redacted description only.
    def encode_with(coder)
      coder.scalar = inspect
    end

    def marshal_dump
      raise TypeError, "#{self.class.name} holds a credential and cannot be serialized"
    end

    def _dump(_level)
      marshal_dump
    end
  end
end
