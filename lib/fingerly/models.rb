# frozen_string_literal: true

require "time"

module Fingerly
  # One signal group that contributed to an event's suspect score.
  #
  # The +SIGNAL_*+ constants are the same strings as {Signal}'s.
  class EventTrigger
    SIGNAL_ATTESTATION_FAILED = Signal::ATTESTATION_FAILED
    SIGNAL_ATTESTATION_MISSING = Signal::ATTESTATION_MISSING
    SIGNAL_ATTESTATION_DOWNGRADE = Signal::ATTESTATION_DOWNGRADE
    SIGNAL_DEVICE_INCONSISTENT = Signal::DEVICE_INCONSISTENT
    SIGNAL_REPORT_INCOMPLETE = Signal::REPORT_INCOMPLETE
    SIGNAL_PROBE_ERRORS = Signal::PROBE_ERRORS
    SIGNAL_FETCH_METADATA_MISSING = Signal::FETCH_METADATA_MISSING
    SIGNAL_WEB_TICKET_MISSING = Signal::WEB_TICKET_MISSING
    SIGNAL_WEB_TICKET_INVALID = Signal::WEB_TICKET_INVALID
    SIGNAL_TAMPERING = Signal::TAMPERING
    SIGNAL_BROWSER_TAMPERING = Signal::BROWSER_TAMPERING
    SIGNAL_CUSTOM_ROOT_CA = Signal::CUSTOM_ROOT_CA
    SIGNAL_SECONDARY_USER_PROFILE = Signal::SECONDARY_USER_PROFILE

    V3_SIGNALS = [
      SIGNAL_ATTESTATION_FAILED,
      SIGNAL_ATTESTATION_DOWNGRADE,
      SIGNAL_DEVICE_INCONSISTENT,
      SIGNAL_REPORT_INCOMPLETE,
      SIGNAL_PROBE_ERRORS,
      SIGNAL_FETCH_METADATA_MISSING,
      SIGNAL_WEB_TICKET_MISSING,
      SIGNAL_WEB_TICKET_INVALID,
      SIGNAL_TAMPERING,
      SIGNAL_CUSTOM_ROOT_CA,
      SIGNAL_SECONDARY_USER_PROFILE
    ].freeze

    # @return [String, nil] the signal or signal group, such as +vpn+ or
    #   +attestation_failed+; see {Signal}
    attr_reader :signal
    # @return [String, nil] optional group identifier when returned alongside a raw signal
    attr_reader :group
    # @return [Integer] the group's combined weight in this score
    attr_reader :weight
    # @return [String, nil] +low+, +medium+ or +high+; see {Confidence}
    attr_reader :confidence

    # @api private
    def initialize(payload)
      @signal = payload["signal"]
      @group = payload["group"]
      @weight = payload["weight"] || 0
      @confidence = payload["confidence"]
      freeze
    end

    def inspect
      "#<Fingerly::EventTrigger #{signal}=#{weight}>"
    end
  end

  # How an {AiAgent}'s claimed identity was checked, and what that found.
  class AiVerification
    # @return [String, nil] +signature+, +ip_list+, +reverse_dns+ or +none+;
    #   see {AiVerificationMethod}. Named for the wire field, so it hides
    #   +Object#method+ on this one class.
    attr_reader :method
    # @return [String, nil] +pass+, +fail+ or +not_attempted+; see
    #   {AiVerificationResult}
    attr_reader :result

    # @api private
    def initialize(payload)
      @method = payload["method"]
      @result = payload["result"]
      freeze
    end

    def inspect
      "#<Fingerly::AiVerification method=#{@method.inspect} result=#{@result.inspect}>"
    end
  end

  # The AI agent behind an event whose +visitor_kind+ is
  # {VisitorKind::AI_BOT}.
  #
  # The identity comes from the agent's user agent, which anyone can copy. It
  # is not verified yet: {#verification} says how far the claim was checked, so
  # read it as a label, not as proof. {#purpose}, {#runtime} and the
  # verification values are plain strings, so a value the API adds later still
  # reads.
  class AiAgent
    # @return [String, nil] the agent as its operator names it, such as
    #   +ChatGPT-User+ or +Claude-User+
    attr_reader :name
    # @return [String, nil] the company that operates it, such as +OpenAI+,
    #   +Anthropic+ or +Google+
    attr_reader :provider
    # @return [String, nil] +training+, +search+, +user_fetch+ or +agent+; see
    #   {AiPurpose}
    attr_reader :purpose
    # @return [String, nil] +provider_cloud+, +hosted_browser+ or
    #   +user_device+; see {AiRuntime}
    attr_reader :runtime
    # @return [Boolean] true when the agent named itself, in its user agent or
    #   a signature
    attr_reader :declared
    # @return [AiVerification, nil] how the claimed identity was checked
    attr_reader :verification

    # @api private
    def initialize(payload)
      @name = payload["name"]
      @provider = payload["provider"]
      @purpose = payload["purpose"]
      @runtime = payload["runtime"]
      @declared = payload["declared"] == true
      verification = payload["verification"]
      @verification = verification.is_a?(Hash) ? AiVerification.new(verification) : nil
      freeze
    end

    def declared? = declared

    def inspect
      "#<Fingerly::AiAgent name=#{name.inspect} provider=#{provider.inspect} " \
        "purpose=#{purpose.inspect}>"
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
    # them. Anything not listed stays reachable through {#raw}. +visitor_id+ is
    # +""+ when the submission was unidentifiable, +reason+ explains why
    # enrichment did not happen when unavailable, and +project_id+ is the UUID
    # string of the Fingerly project the event belongs to (nil on older servers).
    STRING_FIELDS = %w[
      request_id project_id visitor_id state reason environment platform sdk_platform
      sdk_version origin url_host url_path tag ip_network country_code
      country_name asn asn_name anonymity_network agent agent_version os
      device_kind visitor_kind suspect_level
    ].freeze

    STRING_FIELDS.each { |name| attr_reader name.to_sym }

    # @return [Time] when the request arrived
    attr_reader :occurred_at
    # @return [Integer, nil] the suspect score, or nil when unscored
    attr_reader :suspect_score
    # @return [Array<EventTrigger>] the signal groups behind the score; never
    #   nil, and empty when nothing fired
    attr_reader :triggers
    # @return [AiAgent, nil] the AI agent behind the event, present only when
    #   +visitor_kind+ is {VisitorKind::AI_BOT}. The identity comes from the
    #   user agent and is not verified yet; see {AiAgent#verification}.
    attr_reader :ai
    # @return [Hash, nil] an allow-listed view of the archived request, when
    #   one was kept: schema, request id, time, SDK, network, IP
    #   classification and city-level location, risk, attestation and
    #   velocity. It holds no raw signals, user agent or address, and its
    #   contents are not a public contract.
    attr_reader :document
    # @return [Hash] the response body exactly as it arrived, so a field the
    #   API adds after this SDK was released needs no upgrade
    attr_reader :raw

    # @param lenient_time [Boolean] keeps a missing or malformed
    #   +occurred_at+ as nil rather than raising, for +events.verify+, which
    #   answers +too_old+ for it
    # @api private
    def initialize(payload, lenient_time: false)
      STRING_FIELDS.each { |name| instance_variable_set(:"@#{name}", payload[name]) }
      @occurred_at = if lenient_time
                       Models.rfc3339(payload["occurred_at"])
                     else
                       Models.parse_instant(payload["occurred_at"])
                     end
      @suspect_score = payload["suspect_score"]
      @has_document = payload["has_document"] ? true : false
      @triggers = Array(payload["triggers"]).map { |item| EventTrigger.new(item) }.freeze
      @ai = payload["ai"].is_a?(Hash) ? AiAgent.new(payload["ai"]) : nil
      @document = payload["document"]
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

  # The first consumption of an event, from +fingerly.events.consume+.
  class EventConsumption
    # @return [String, nil] the consumed event's request id
    attr_reader :request_id
    # @return [String, nil] when it was consumed, as the API sent it (RFC 3339)
    attr_reader :consumed_at
    # @return [Boolean] true for the call that consumed the event
    attr_reader :first
    # @return [Hash] the response body exactly as it arrived
    attr_reader :raw

    # @api private
    def initialize(payload)
      @request_id = payload["request_id"].is_a?(String) ? payload["request_id"] : nil
      @consumed_at = payload["consumed_at"].is_a?(String) ? payload["consumed_at"] : nil
      @first = payload["first"] == true
      @raw = payload
      freeze
    end

    def first? = first

    def inspect
      "#<Fingerly::EventConsumption request_id=#{request_id.inspect} first=#{first}>"
    end
  end

  # The answer of +fingerly.events.verify+.
  #
  # {#reason} is +""+ when {#ok?}, and otherwise the first check that failed,
  # as one of the {VerifyReason} strings. The score is not checked: apply your own
  # policy to {#event} after {#ok?}.
  class EventVerification
    NOT_FOUND = VerifyReason::NOT_FOUND
    TOO_OLD = VerifyReason::TOO_OLD
    TAG_MISMATCH = VerifyReason::TAG_MISMATCH
    UNIDENTIFIABLE = VerifyReason::UNIDENTIFIABLE
    UNSCORED = VerifyReason::UNSCORED
    ALREADY_CONSUMED = VerifyReason::ALREADY_CONSUMED

    # Every failure reason, in the order the checks run.
    REASONS = [NOT_FOUND, TOO_OLD, TAG_MISMATCH, UNIDENTIFIABLE, UNSCORED, ALREADY_CONSUMED].freeze

    # @return [Boolean] whether every check passed
    attr_reader :ok
    # @return [String] the failed check, or +""+ when {#ok}
    attr_reader :reason
    # @return [Event, nil] the event read; nil only for +not_found+
    attr_reader :event

    # @api private
    def initialize(reason:, event:)
      @ok = reason.empty?
      @reason = reason
      @event = event
      freeze
    end

    def ok? = ok

    def inspect
      "#<Fingerly::EventVerification ok=#{ok} reason=#{reason.inspect}>"
    end
  end

  # What Apple holds for the device behind an event, from
  # +fingerly.device_check.query+. The bits mean what you decide; Fingerly
  # never reads them.
  class DeviceCheckBits
    # @return [Boolean] false when Apple holds no bits for the device yet;
    #   both bits are then false
    attr_reader :found
    # @return [Boolean] the first bit
    attr_reader :bit0
    # @return [Boolean] the second bit
    attr_reader :bit1
    # @return [String, nil] when the bits last changed, as +YYYY-MM+; nil when
    #   Apple holds no bits
    attr_reader :last_update
    # @return [Hash] the response body exactly as it arrived
    attr_reader :raw

    # @api private
    def initialize(payload)
      @found = payload["found"] == true
      @bit0 = payload["bit0"] == true
      @bit1 = payload["bit1"] == true
      @last_update = payload["last_update"].is_a?(String) ? payload["last_update"] : nil
      @raw = payload
      freeze
    end

    def found? = found

    def inspect
      "#<Fingerly::DeviceCheckBits found=#{found} bit0=#{bit0} bit1=#{bit1}>"
    end
  end

  # The bits Apple accepted, from +fingerly.device_check.write+.
  class DeviceCheckWrite
    # @return [Boolean, nil] the value set for the first bit; nil when the
    #   write left it out
    attr_reader :bit0
    # @return [Boolean, nil] the value set for the second bit; nil when the
    #   write left it out
    attr_reader :bit1
    # @return [Hash] the response body exactly as it arrived
    attr_reader :raw

    # @api private
    def initialize(payload)
      @bit0 = [true, false].include?(payload["bit0"]) ? payload["bit0"] : nil
      @bit1 = [true, false].include?(payload["bit1"]) ? payload["bit1"] : nil
      @raw = payload
      freeze
    end

    def inspect
      "#<Fingerly::DeviceCheckWrite bit0=#{bit0.inspect} bit1=#{bit1.inspect}>"
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

  # One request your server served, as raw input for
  # +fingerly.agents.report_sightings+. Nothing here is judged by the SDK: the
  # server decides what sent it.
  class AgentSightingInput
    # @return [String] the +User-Agent+ header as received, or +""+
    attr_reader :user_agent
    # @return [String] the client's one IP literal, from a trusted source
    attr_reader :client_ip
    # @return [String, nil] the +Host+ the request was sent to
    attr_reader :host
    # @return [String, nil] the request method, sent as +method+
    attr_reader :request_method
    # @return [String, nil] the +Signature+ header
    attr_reader :signature
    # @return [String, nil] the +Signature-Input+ header
    attr_reader :signature_input
    # @return [String, nil] the +Signature-Agent+ header
    attr_reader :signature_agent
    # @return [Integer, nil] how many times this request was served since it
    #   was last reported, this one included
    attr_reader :count

    def initialize(user_agent:, client_ip:, host: nil, request_method: nil, signature: nil,
                   signature_input: nil, signature_agent: nil, count: nil)
      @user_agent = user_agent
      @client_ip = client_ip
      @host = host
      @request_method = request_method
      @signature = signature
      @signature_input = signature_input
      @signature_agent = signature_agent
      @count = count
      freeze
    end

    # @return [Hash{String=>Object}] the item as the API reads it
    def to_h
      {
        "user_agent" => user_agent, "client_ip" => client_ip, "host" => host,
        "method" => request_method, "signature" => signature,
        "signature_input" => signature_input, "signature_agent" => signature_agent,
        "count" => count
      }.compact
    end

    # The fields are a visitor's request; none of them is printed.
    def inspect
      "#<Fingerly::AgentSightingInput count=#{count.inspect}>"
    end
  end

  # What the server said sent one reported request.
  #
  # {AgentSightings::UNKNOWN} is the one answer that did not come from the
  # server: nothing is known yet, so serve the request as usual.
  class AgentSighting
    # @return [Integer] seconds this answer may be reused for the same user
    #   agent, address and +Signature-Agent+; 0 for a signed request
    attr_reader :ttl
    # @return [String] +human+, +ai_bot+, +automation+ or +search_crawler+;
    #   see {VisitorKind}. The API can add values, so keep an +else+ branch.
    attr_reader :visitor_kind
    # @return [String, nil] the agent's name where the server knows it, such
    #   as +GPTBot+ or +Googlebot+
    attr_reader :agent
    # @return [AiAgent, nil] present when {#visitor_kind} is
    #   {VisitorKind::AI_BOT}
    attr_reader :ai

    # @api private
    def initialize(payload)
      ttl = payload["ttl"]
      @ttl = ttl.is_a?(Integer) && ttl.positive? ? ttl : 0
      kind = payload["visitor_kind"]
      @visitor_kind = kind.is_a?(String) ? kind : ""
      @agent = payload["agent"].is_a?(String) ? payload["agent"] : nil
      @ai = payload["ai"].is_a?(Hash) ? AiAgent.new(payload["ai"]) : nil
      freeze
    end

    def inspect
      "#<Fingerly::AgentSighting visitor_kind=#{visitor_kind.inspect} agent=#{agent.inspect} " \
        "ttl=#{ttl}>"
    end
  end

  # The server's answer to +fingerly.agents.report_sightings+.
  class AgentSightingsReport
    # @return [String] names the classification rules; when it changes, every
    #   remembered answer is stale
    attr_reader :rules_version
    # @return [Array<AgentSighting>] one answer per reported request, in the
    #   same order
    attr_reader :items
    # @return [Hash] the response body exactly as it arrived
    attr_reader :raw

    # @api private
    # @raise [Error] if the body is not an answer of this shape
    def initialize(payload)
      items = payload["items"]
      version = payload["rules_version"]
      unless items.is_a?(Array) && version.is_a?(String) && items.all?(Hash)
        raise Error, "Fingerly API returned an agent sightings answer of another shape"
      end

      @rules_version = version
      @items = items.map { |item| AgentSighting.new(item) }.freeze
      @raw = payload
      freeze
    end

    def inspect
      "#<Fingerly::AgentSightingsReport rules_version=#{rules_version.inspect} " \
        "items=#{items.size}>"
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

    RFC3339 = /\A\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})\z/

    # A strict RFC 3339 date-time, or nil for anything else, a date alone
    # included.
    def rfc3339(value)
      return nil unless value.is_a?(String) && value.match?(RFC3339)

      Time.iso8601(value.upcase)
    rescue ArgumentError
      nil
    end
  end
end
