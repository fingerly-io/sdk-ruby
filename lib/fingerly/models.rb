# frozen_string_literal: true

require "time"

module Fingerly
  # One signal group that contributed to an event's suspect score.
  class EventTrigger
    # @return [String, nil] the signal group, such as +vpn+ or +bot+
    attr_reader :signal
    # @return [Integer] the group's combined weight in this score
    attr_reader :weight
    # @return [String, nil] +low+, +medium+ or +high+
    attr_reader :confidence

    # @api private
    def initialize(payload)
      @signal = payload["signal"]
      @weight = payload["weight"] || 0
      @confidence = payload["confidence"]
      freeze
    end

    def inspect
      "#<Fingerly::EventTrigger #{signal}=#{weight}>"
    end
  end

  # A stored identification event.
  #
  # {#suspect_score} is +nil+ when the request was not scored, which must not
  # be read as zero: a visitor about whom nothing fired scores 0, while a
  # submission that was never enriched has no score at all. {#scored?} states
  # the distinction at the call site.
  class Event
    # Fields copied straight from the response, in the order the API documents
    # them. Anything not listed stays reachable through {#raw}.
    STRING_FIELDS = %w[
      request_id visitor_id state environment platform sdk_platform sdk_version
      origin url_host url_path tag ip_address country_code country_name asn
      asn_name anonymity_network agent agent_version os device_kind visitor_kind
      suspect_level
    ].freeze

    STRING_FIELDS.each { |name| attr_reader name.to_sym }

    # @return [Time] when the request arrived
    attr_reader :occurred_at
    # @return [Integer, nil] the suspect score, or nil when unscored
    attr_reader :suspect_score
    # @return [Array<EventTrigger>] the signal groups behind the score; never
    #   nil, and empty when nothing fired
    attr_reader :triggers
    # @return [Hash, nil] the archived submission, when one was kept. Its
    #   contents are deliberately opaque, not a public contract.
    attr_reader :document
    # @return [Hash, nil] the deferred report attached to this request, when
    #   one arrived. Also opaque.
    attr_reader :deferred_signals
    # @return [Hash] the response body exactly as it arrived, so a field the
    #   API adds after this SDK was released needs no upgrade
    attr_reader :raw

    # @api private
    def initialize(payload)
      STRING_FIELDS.each { |name| instance_variable_set(:"@#{name}", payload[name]) }
      @occurred_at = Models.parse_instant(payload["occurred_at"])
      @suspect_score = payload["suspect_score"]
      @has_document = payload["has_document"] ? true : false
      @triggers = Array(payload["triggers"]).map { |item| EventTrigger.new(item) }.freeze
      @document = payload["document"]
      @deferred_signals = payload["deferred_signals"]
      @raw = payload
      freeze
    end

    # Whether the full submission was archived.
    # @return [Boolean]
    def has_document?
      @has_document
    end

    # Whether the API assigned this event a suspect score.
    #
    # Prefer it to a nil check: it states the question being asked.
    # @return [Boolean]
    def scored?
      !@suspect_score.nil?
    end

    def inspect
      "#<Fingerly::Event request_id=#{request_id.inspect} visitor_id=#{visitor_id.inspect}>"
    end
  end

  # One page of events, newest first.
  class EventPage
    include Enumerable

    # @return [Array<Event>] the events on this page; never nil, possibly empty
    attr_reader :rows
    # @return [Integer] the one-based page number returned
    attr_reader :page
    # @return [Integer] rows per page the server applied
    attr_reader :page_size
    # @return [Hash] the response body exactly as it arrived
    attr_reader :raw

    # @api private
    def initialize(payload)
      @rows = Array(payload["rows"]).map { |item| Event.new(item) }.freeze
      @page = payload["page"] || 0
      @page_size = payload["page_size"] || 0
      @raw = payload
      freeze
    end

    # Yields each event, so a page is usable anywhere an Enumerable is.
    def each(&block)
      rows.each(&block)
    end

    def inspect
      "#<Fingerly::EventPage page=#{page} page_size=#{page_size} rows=#{rows.size}>"
    end
  end

  # The envelope every webhook delivery shares.
  #
  # {#data} is left as a plain Hash, so a new event type needs no SDK upgrade.
  class WebhookEvent
    # @return [String, nil] identifies this delivery. Persist it to
    #   deduplicate: a webhook may arrive more than once.
    attr_reader :id
    # @return [String, nil] the event name, such as +identification.completed+
    attr_reader :type
    # @return [Integer, nil] the envelope version
    attr_reader :version
    # @return [String, nil] the organization the event belongs to
    attr_reader :organization_id
    # @return [String, nil] the deployment the event came from
    attr_reader :environment
    # @return [Time, nil] when Fingerly recorded the event
    attr_reader :created_at
    # @return [Hash] the event-specific payload
    attr_reader :data
    # @return [Hash] the delivery body exactly as it arrived
    attr_reader :raw

    # @api private
    def initialize(payload)
      @id = payload["id"]
      @type = payload["type"]
      @version = payload["version"]
      @organization_id = payload["organization_id"]
      @environment = payload["environment"]
      @created_at = payload["created_at"] ? Models.parse_instant(payload["created_at"]) : nil
      @data = payload["data"] || {}
      @raw = payload
      freeze
    end

    def inspect
      "#<Fingerly::WebhookEvent id=#{id.inspect} type=#{type.inspect}>"
    end
  end

  # Shared decoding helpers.
  #
  # @api private
  module Models
    module_function

    # Reads an RFC 3339 timestamp into a Time.
    #
    # @raise [Error] if the API sent something that is not one
    def parse_instant(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      raise Error, "Fingerly API returned a timestamp that is not RFC 3339"
    end
  end
end
