# frozen_string_literal: true

require "net/http"
require "openssl"
require "timeout"
require "uri"

module Fingerly
  # One HTTP exchange, bounded end to end.
  #
  # Net::HTTP has +open_timeout+, +read_timeout+ and +write_timeout+, but each
  # bounds a single operation: a server that answers and then dribbles a byte
  # every second would satisfy all three forever. The socket's timeouts are
  # shrunk to whatever is left of the deadline before each operation and each
  # body chunk, and one Timeout around the whole exchange covers what those
  # cannot reach: Net::HTTP reads the status line and every header line with
  # the full read timeout each, so a server trickling header lines would
  # otherwise hold the call for as long as it liked. Under a fiber scheduler
  # Timeout hands the wait to the scheduler.
  #
  # Connections are kept per thread. Net::HTTP is not safe to share between
  # threads, and a Ruby application server runs one request per thread, so a
  # thread-local connection is reused exactly as far as it is safe to and no
  # further. They are recycled by age as well, because a connection held for
  # the life of a process pins whatever DNS answered first and will eventually
  # be closed by the other end without telling anybody.
  #
  # The pool is keyed by destination rather than by transport instance, so an
  # application that builds a client per request reuses one socket rather than
  # stranding a new one on the thread every time.
  #
  # Nothing here needs an asynchronous twin. Net::HTTP has honoured the fiber
  # scheduler since Ruby 3.0, so under Falcon or the async gem these same
  # blocking reads yield to the scheduler instead of holding the thread.
  #
  # @api private
  class Transport
    include Redacted

    # A response body is small; anything larger did not come from this API.
    MAX_BODY_BYTES = 16 * 1024 * 1024

    # How long a pooled connection may live before it is reopened.
    RECYCLE_AFTER = 60

    Result = Struct.new(:status, :headers, :body, keyword_init: true)

    # @param origin [String] scheme and authority, without a trailing slash
    # @param timeout [Numeric] the deadline for one exchange, in seconds
    # @param configure_http [Proc, nil] receives the Net::HTTP before it starts
    def initialize(origin:, timeout:, configure_http: nil)
      @uri = URI.parse(origin)
      @timeout = timeout
      @configure_http = configure_http
      # A caller-supplied configure_http may set anything at all, so two
      # transports share a connection only when neither has one.
      @pool_key = [@uri.scheme, @uri.host, @uri.port, configure_http&.object_id].freeze
    end

    # Performs one request and reads the whole response.
    #
    # @param method [Class] a Net::HTTPRequest subclass
    # @param path [String] the path and query to request
    # @param headers [Hash{String=>String}] headers to send
    # @param body [String, nil] the request body
    # @return [Result]
    # @raise [TimeoutError] if the deadline passes at any point
    # @raise [ConnectionError] if the API cannot be reached
    def call(method, path, headers, body = nil)
      request = method.new(path, headers)
      request.body = body if body
      # Net::HTTP's own retry would resend on a connection error; reuse is
      # handled here instead, where an idempotent request can be told from one
      # that must never be sent twice.
      idempotent = method == Net::HTTP::Get

      # One budget for the whole call, so reopening a closed connection cannot
      # quietly buy a second timeout's worth of time.
      Timeout.timeout(@timeout, DeadlineExceeded) do
        perform(request, deadline: now + @timeout, idempotent: idempotent)
      end
    rescue DeadlineExceeded
      # Interrupted mid-exchange, the connection is in no state to reuse.
      close
      raise TimeoutError, "The Fingerly request timed out"
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
      raise TimeoutError, "The Fingerly request timed out (#{e.class})"
    rescue SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError,
           Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError => e
      raise ConnectionError, "Could not reach the Fingerly API (#{e.class})"
    end

    # Closes this thread's connection, if it has one.
    def close
      http = pool[@pool_key]&.first
      discard(http) if http
    end

    private

    def redacted_fields
      [["origin", "#{@uri.scheme}://#{@uri.host}:#{@uri.port}"], ["timeout", @timeout]]
    end

    def perform(request, deadline:, idempotent:)
      http, reused = connection
      begin
        exchange(http, request, deadline)
      rescue IOError, SystemCallError, Net::HTTPBadResponse
        # A connection the other end closed while it was idle fails on its
        # next use. Reopening and sending again is recovery, not a retry, so
        # it happens only for a reused connection and only for a request that
        # may safely arrive twice. A timeout is deliberately not in this list:
        # a slow server is not a broken connection.
        raise unless reused && idempotent

        discard(http)
        fresh, = connection
        exchange(fresh, request, deadline)
      end
    end

    def exchange(http, request, deadline)
      apply_timeouts(http, deadline)
      http.start unless http.started?
      apply_timeouts(http, deadline)

      # The result is captured rather than returned from the block. Net::HTTP
      # decides whether the connection may be kept alive after the block ends,
      # and a non-local exit would skip that: the next request on this thread
      # would then be written to a socket the server had already said it was
      # closing.
      result = nil
      http.request(request) do |response|
        body = +""
        response.read_body do |chunk|
          body << chunk
          raise Error, "Fingerly API returned more than #{MAX_BODY_BYTES} bytes" if
            body.bytesize > MAX_BODY_BYTES

          # Shrink the socket's own timeout to what is left of the deadline, so
          # a stalled body cannot outlive it.
          apply_timeouts(http, deadline)
        end
        result = Result.new(
          status: response.code.to_i, headers: response.to_hash, body: body
        )
      end
      result
    end

    # @raise [TimeoutError] when nothing is left of the deadline
    def apply_timeouts(http, deadline)
      left = deadline - now
      raise TimeoutError, "The Fingerly request timed out" if left <= 0

      http.open_timeout = left
      http.read_timeout = left
      http.write_timeout = left
    end

    # @return [Array(Net::HTTP, Boolean)] the connection and whether it existed
    def connection
      http, opened_at = pool[@pool_key]
      if http && (!http.started? || now - opened_at > RECYCLE_AFTER)
        discard(http)
        http = nil
      end
      return [http, true] if http

      http = build
      pool[@pool_key] = [http, now]
      [http, false]
    end

    # Where this thread keeps its open connections, keyed by destination.
    def pool
      Thread.current[:fingerly_connections] ||= {}
    end

    def build
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = @uri.scheme == "https"
      http.max_retries = 0
      @configure_http&.call(http)
      http
    end

    def discard(http)
      http.finish if http.started?
    rescue IOError
      # Already closed by the other end; nothing left to release.
    ensure
      pool.delete(@pool_key)
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Raised by the overall deadline; never escapes {#call}.
    class DeadlineExceeded < StandardError; end
    private_constant :DeadlineExceeded
  end
end
