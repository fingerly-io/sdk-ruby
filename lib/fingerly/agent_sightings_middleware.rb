# frozen_string_literal: true

module Fingerly
  class AgentSightings
    # Rack middleware that reports the responses worth reporting to an
    # {AgentSightings}.
    #
    #   # config/application.rb
    #   config.middleware.use Fingerly::AgentSightings::Middleware, SIGHTINGS
    #
    # By default it reports every response with a +Content-Type+ of
    # +text/html+ or +application/xhtml+xml+, and every request for
    # +/robots.txt+, +/llms.txt+ and +/llms-full.txt+, whatever the status.
    # Static assets, API routes and health checks are left out unless you
    # include them. What is reported is decided by your own response and path,
    # never by the visitor's user agent, address or headers.
    #
    # The report is made in memory after the application answered, so it
    # never delays the response, and nothing it does can fail one.
    class Middleware
      # The response media types reported by default.
      DEFAULT_CONTENT_TYPES = %w[text/html application/xhtml+xml].freeze

      # @param app [#call] the rest of the Rack stack
      # @param sightings [AgentSightings] where the reports go
      # @param content_types [Array<String>] the response media types
      #   reported, replacing {DEFAULT_CONTENT_TYPES}; matched without regard
      #   to case or parameters
      # @param include_path_prefixes [Array<String>] paths reported whatever
      #   their content type, such as +/feed+
      # @param exclude_path_prefixes [Array<String>] paths never reported;
      #   these win over everything else
      # @raise [ConfigurationError] for an option of the wrong shape
      def initialize(app, sightings, content_types: DEFAULT_CONTENT_TYPES,
                     include_path_prefixes: [], exclude_path_prefixes: [])
        unless sightings.is_a?(AgentSightings)
          raise ConfigurationError, "sightings must be a Fingerly::AgentSightings"
        end

        @app = app
        @sightings = sightings
        @content_types = media_types(content_types)
        @include = prefixes(include_path_prefixes, "include_path_prefixes")
        @exclude = prefixes(exclude_path_prefixes, "exclude_path_prefixes")
        freeze
      end

      # @param env [Hash] the Rack environment
      # @return [Array(Integer, Hash, #each)] the application's response,
      #   untouched
      def call(env)
        response = @app.call(env)
        begin
          @sightings.report(env) if reported?(env["PATH_INFO"].to_s, response[1])
        rescue StandardError
          # Reporting never fails a response.
          nil
        end
        response
      end

      # Whether a response is in scope.
      #
      # @param path [String] the application-relative path, +PATH_INFO+
      # @param headers [Hash] the response headers
      # @return [Boolean]
      def reported?(path, headers)
        return false if @exclude.any? { |prefix| path.start_with?(prefix) }
        return true if WELL_KNOWN_PATHS.include?(path)
        return true if @include.any? { |prefix| path.start_with?(prefix) }

        @content_types.include?(media_type(headers))
      end

      def inspect
        "#<Fingerly::AgentSightings::Middleware content_types=#{@content_types.inspect}>"
      end

      # A Content-Type's media type, lowercase and without parameters, or nil
      # when it names none.
      #
      # @api private
      def self.media(value)
        media = value.split(";", 2).first.to_s.strip.downcase
        media.empty? ? nil : media
      end

      private

      # Rack 3 names headers in lowercase; Rack 2 applications may not.
      def media_type(headers)
        value = headers["content-type"] || headers["Content-Type"]
        if value.nil? && headers.respond_to?(:each)
          headers.each { |name, found| value = found if name.to_s.casecmp?("content-type") }
        end
        value = value.first if value.is_a?(Array)
        return nil unless value.is_a?(String)

        Middleware.media(value)
      end

      # The configured types read as a response's are, so +"text/html;
      # charset=utf-8"+ or +" Text/HTML"+ still match.
      def media_types(value)
        types = strings(value, "content_types").map { |type| Middleware.media(type) }
        if types.include?(nil)
          raise ConfigurationError, "content_types must be media types such as text/html"
        end

        types.uniq.freeze
      end

      def strings(value, name)
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? }
          raise ConfigurationError, "#{name} must be an Array of non-empty Strings"
        end

        value
      end

      def prefixes(value, name)
        list = strings(value, name)
        unless list.all? { |prefix| prefix.start_with?("/") }
          raise ConfigurationError, "#{name} must be paths that start with /"
        end

        list.dup.freeze
      end
    end
  end
end
