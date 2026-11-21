# frozen_string_literal: true

require "digest"
require "ipaddr"

module Fingerly
  # The key and request reading behind {AgentSightings}; see agent_sightings.rb.
  class AgentSightings
    # The cache key of section 4.1 of the agent sightings contract.
    #
    # @return [String, nil] 32 lowercase hex characters, or nil when
    #   +client_ip+ is not one IP literal
    def self.key(user_agent:, client_ip:, signature_agent: "", signed: false)
      ip = Key.canonical_ip(client_ip)
      ip && Key.digest(user_agent.to_s, ip, signature_agent.to_s, signed)
    end

    # An address in its canonical text form: IPv4 dotted, an IPv4-mapped IPv6
    # address as its IPv4 address, and other IPv6 as RFC 5952 has it.
    #
    # @return [String, nil] nil when the value is not one IP literal
    def self.canonical_ip(value)
      Key.canonical_ip(value)
    end

    # @api private
    def self.monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # The cache key of section 4.1 of the agent sightings contract, and the
    # canonical address it hashes.
    #
    # @api private
    module Key
      module_function

      # @return [String] 32 lowercase hex characters
      def digest(user_agent, ip, signature_agent, signed)
        sha = Digest::SHA256.new
        [user_agent, ip, signature_agent].each { |part| sha << part.b << "\0" }
        sha << (signed ? "1" : "0")
        sha.digest.byteslice(0, 16).unpack1("H*")
      end

      # @return [String, nil] nil when the value is not one IP literal
      def canonical_ip(value)
        return nil unless Config.ip_literal?(value)

        address = IPAddr.new(value)
        return address.to_s if address.ipv4?
        return address.native.to_s if address.ipv4_mapped?

        rfc5952(address.hton.unpack("n8"))
      rescue IPAddr::Error
        nil
      end

      # Eight 16-bit groups in lowercase hex, with the longest run of two or
      # more zero groups shortened to +::+, the first one when two are as long.
      def rfc5952(groups)
        best_at = nil
        best_len = 1
        run_at = nil
        groups.each_with_index do |group, index|
          unless group.zero?
            run_at = nil
            next
          end

          run_at ||= index
          next unless index - run_at + 1 > best_len

          best_at = run_at
          best_len = index - run_at + 1
        end
        hex = groups.map { |group| group.to_s(16) }
        return hex.join(":") if best_at.nil?

        "#{hex[0...best_at].join(":")}::#{hex[(best_at + best_len)..].join(":")}"
      end
    end

    # Reads what would be reported for one request out of its Rack
    # environment.
    #
    # @api private
    class Reader
      def initialize(client_ip, log)
        @client_ip = client_ip
        @log = log
        @logged = false
      end

      # @return [Sighting, nil] nil when the request is not reported at all:
      #   a user agent over the limit, or no usable client address
      def sighting(env)
        user_agent = env["HTTP_USER_AGENT"]
        user_agent = "" unless user_agent.is_a?(String)
        return nil if user_agent.bytesize > MAX_HEADER_BYTES

        ip = client_address(env)
        return nil if ip.nil?

        # A header over the limit is left out, and counts as absent for the
        # key too: the server never sees it.
        signature = header(env, "HTTP_SIGNATURE")
        signature_input = header(env, "HTTP_SIGNATURE_INPUT")
        signature_agent = header(env, "HTTP_SIGNATURE_AGENT")
        signed = !signature.nil? && !signature_input.nil?
        fields = {
          user_agent: user_agent, client_ip: ip, host: header(env, "HTTP_HOST"),
          request_method: env["REQUEST_METHOD"].to_s, signature: signature,
          signature_input: signature_input, signature_agent: signature_agent
        }.compact
        Sighting.new(Key.digest(user_agent, ip, signature_agent.to_s, signed), signed, fields,
                     ITEM_OVERHEAD + fields.sum { |_name, value| value.bytesize })
      end

      private

      # A header as received, or nil when absent, empty or over the limit.
      def header(env, name)
        value = env[name]
        return nil unless value.is_a?(String) && !value.empty?

        value.bytesize > MAX_HEADER_BYTES ? nil : value
      end

      # The same trusted address the proxy forwards, canonical, or nil.
      def client_address(env)
        returned = begin
          @client_ip.call(ProxyRequest.new(env, env["PATH_INFO"].to_s))
        rescue StandardError => e
          e
        end
        ip = Key.canonical_ip(returned)
        return ip if ip
        return nil if @logged

        @logged = true
        shown = returned.is_a?(Exception) ? "raised" : "returned"
        @log.call("fingerly agent sightings: client_ip #{shown} #{returned.class}, not one IP " \
                  "address; such requests are not reported (logged once)")
        nil
      end
    end
  end
end
