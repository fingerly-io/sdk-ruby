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
  # Idle connections live in one pool per process, keyed by destination.
  # Net::HTTP cannot be used by two threads or fibers at once, so each exchange
  # checks a connection out and hands it back when it is done. A thread-local
  # or fiber-local connection would be reused only by the same thread or
  # fiber: under Falcon, which runs each client connection in its own fiber,
  # that meant a new upstream socket per visitor, stranded until garbage
  # collection. A pool shared by everything reuses a socket whoever asks next.
  #
  # Connections are recycled by age, because one held for the life of a
  # process pins whatever DNS answered first, and dropped after sitting idle,
  # because the other end will eventually close it without telling anybody.
  # Keying by destination rather than by transport instance means an
  # application that builds a client per request still reuses sockets.
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

    # How long a pooled connection may live before it is reopened, so DNS is
    # asked again at least this often.
    RECYCLE_AFTER = 60

    # How long a connection may sit idle in the pool and still be reused. Well
    # under the idle timeouts servers and load balancers apply, so a reused
    # socket is one the other end has not yet given up on.
    IDLE_TIMEOUT = 15

    # Idle connections kept per destination. Enough that a burst of a few
    # hundred concurrent requests hands its sockets back rather than closing
    # them; never more open at rest than this.
    MAX_IDLE = 256

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
      # perform has already discarded the interrupted connection.
      raise TimeoutError, "The Fingerly request timed out"
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
      raise TimeoutError, "The Fingerly request timed out (#{e.class})"
    rescue SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError,
           Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError => e
      raise ConnectionError, "Could not reach the Fingerly API (#{e.class})"
    end

    # Closes the idle connections kept for this destination.
    def close
      Transport.drain(@pool_key).each { |entry| discard(entry.first) }
    end

    # One entry per idle connection: the Net::HTTP, when it was opened, and
    # when it was last handed back.
    Idle = Struct.new(:http, :opened_at, :released_at)

    @idle = {}
    @lock = Mutex.new
    @pid = Process.pid

    class << self
      # @api private
      # @return [Array(Idle, Array<Idle>)] the most recently used usable
      #   connection, or nil, and the stale ones the caller must close
      def checkout(key, now)
        @lock.synchronize do
          list = idle_for(key)
          stale = prune(list, now)
          [list.pop, stale]
        end
      end

      # @api private
      # @return [Array(Boolean, Array<Idle>)] whether the pool kept it, and the
      #   stale ones the caller must close
      def checkin(key, entry, now)
        @lock.synchronize do
          list = idle_for(key)
          stale = prune(list, now)
          next [false, stale] if list.size >= MAX_IDLE

          list.push(entry)
          [true, stale]
        end
      end

      # @api private
      def drain(key)
        @lock.synchronize { idle_for(key).slice!(0..) }
      end

      # @api private
      # @return [Integer] idle connections held for a destination
      def idle_count(key)
        @lock.synchronize { idle_for(key).size }
      end

      private

      def idle_for(key)
        # A forked child must never write to a socket its parent also holds.
        # Dropping the references closes nothing the parent still uses.
        unless @pid == Process.pid
          @idle = {}
          @pid = Process.pid
        end
        @idle[key] ||= []
      end

      # The oldest entries sit at the front; take them while they are stale.
      def prune(list, now)
        stale = []
        stale << list.shift while list.first && stale?(list.first, now)
        stale
      end

      def stale?(entry, now)
        now - entry.released_at > IDLE_TIMEOUT || now - entry.opened_at > RECYCLE_AFTER
      end
    end

    private

    def redacted_fields
      [["origin", "#{@uri.scheme}://#{@uri.host}:#{@uri.port}"], ["timeout", @timeout]]
    end

    def perform(request, deadline:, idempotent:)
      entry, reused = connection
      begin
        result = exchange(entry.http, request, deadline)
      rescue IOError, SystemCallError, Net::HTTPBadResponse
        discard(entry.http)
        # A connection the other end closed while it was idle fails on its
        # next use. Reopening and sending again is recovery, not a retry, so
        # it happens only for a reused connection and only for a request that
        # may safely arrive twice. A timeout is deliberately not in this list:
        # a slow server is not a broken connection.
        raise unless reused && idempotent

        entry = fresh
        begin
          result = exchange(entry.http, request, deadline)
        rescue Exception # rubocop:disable Lint/RescueException
          discard(entry.http)
          raise
        end
      rescue Exception # rubocop:disable Lint/RescueException
        # Anything else, the overall deadline included, leaves the connection
        # in an unknown state, so it is never handed to another caller.
        discard(entry.http)
        raise
      end
      release(entry)
      result
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

    # @return [Array(Idle, Boolean)] a connection and whether it was reused
    def connection
      loop do
        entry, stale = Transport.checkout(@pool_key, now)
        stale.each { |old| discard(old.http) }
        return [fresh, false] if entry.nil?
        return [entry, true] if entry.http.started?

        discard(entry.http)
      end
    end

    def release(entry)
      return discard(entry.http) unless entry.http.started?

      entry.released_at = now
      kept, stale = Transport.checkin(@pool_key, entry, now)
      stale.each { |old| discard(old.http) }
      discard(entry.http) unless kept
    end

    def fresh
      Idle.new(build, now, now)
    end

    def build
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = @uri.scheme == "https"
      http.max_retries = 0
      # Net::HTTP reconnects by itself after this long idle; keep it in step
      # with the pool's own idea of a usable connection.
      http.keep_alive_timeout = IDLE_TIMEOUT
      @configure_http&.call(http)
      http
    end

    def discard(http)
      http.finish if http.started?
    rescue IOError
      # Already closed by the other end; nothing left to release.
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Raised by the overall deadline; never escapes {#call}.
    class DeadlineExceeded < StandardError; end
    private_constant :DeadlineExceeded
  end
end
