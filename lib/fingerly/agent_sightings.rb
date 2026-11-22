# frozen_string_literal: true

module Fingerly
  # Reports the requests your server served, so AI crawlers and fetchers that
  # never run a page's JavaScript are seen, and answers what sent a request
  # from what the server said about it before.
  #
  # Build one per process at start-up and share it: it is safe to use from
  # every thread and fiber. Mount {AgentSightings::Middleware} to report, and
  # call {#lookup} where a decision needs the answer:
  #
  #   SIGHTINGS = Fingerly::AgentSightings.new(
  #     secret_key: ENV.fetch("FINGERLY_SECRET_KEY"),
  #     client_ip: ->(request) { request.header("CF-Connecting-IP") }
  #   )
  #
  #   answer = SIGHTINGS.lookup(request.env)
  #   if answer.visitor_kind == Fingerly::VisitorKind::AI_BOT
  #     # ...
  #   end
  #
  # The SDK forwards raw input and remembers answers; it never judges a user
  # agent or an address itself. Reports go out from one background thread,
  # never from a request, and every failure leaves requests served as usual:
  # {#lookup} then answers {UNKNOWN}. Memory is bounded by {#capacity} answers
  # and {MAX_PENDING} pending reports. The path, query string, cookies,
  # +Authorization+, other headers and bodies are never sent or logged.
  class AgentSightings
    include Redacted

    # The answer when nothing is known about a request: serve it as usual.
    # Its +visitor_kind+ is +""+, which no server answer carries, so a check
    # against a {VisitorKind} constant fails open.
    UNKNOWN = AgentSighting.new("ttl" => 0, "visitor_kind" => "")

    DEFAULT_CAPACITY = 4096
    MAX_CAPACITY = 65_536
    # Pending reports held at most; a new request past this stays {UNKNOWN}
    # and is counted in {#dropped_count}.
    MAX_PENDING = 1000
    # A flush sends at most this many items...
    FLUSH_ITEMS = Agents::MAX_SIGHTINGS
    # ...and at most this many bytes of fields; reaching either starts one.
    FLUSH_BYTES = 64 * 1024
    # Seconds after its oldest item that a buffer is flushed.
    FLUSH_AFTER = 2
    # Seconds one flush may take, the response body included.
    FLUSH_DEADLINE = 5
    # Seconds {#flush} waits for a flush already in flight: its deadline and a
    # second of margin.
    IN_FLIGHT_WAIT = FLUSH_DEADLINE + 1
    # The longest header value reported, in bytes.
    MAX_HEADER_BYTES = 4096
    # The most requests one item may stand for.
    MAX_COUNT = 1_000_000

    # Seconds between the background thread's checks.
    TICK = 0.25
    # Seconds reporting stops after the key was refused.
    AUTH_PAUSE = 60
    # Seconds reporting stops after a 429 that named no Retry-After.
    RATE_LIMIT_PAUSE = 60
    # The shortest stop after a 429, whatever its Retry-After said.
    RETRY_AFTER_MIN = 1
    # The longest stop after a 429, whatever its Retry-After said, so a huge
    # value cannot end reporting for the life of the process.
    RETRY_AFTER_MAX = 86_400
    # Backoff bounds, in seconds, after a 503 or a transport error.
    BACKOFF_MIN = 1
    BACKOFF_MAX = 60
    # Seconds between two log lines of one kind.
    LOG_INTERVAL = 60

    # Paths reported whatever their content type.
    WELL_KNOWN_PATHS = %w[/robots.txt /llms.txt /llms-full.txt].freeze

    # @return [Integer] the most answers remembered
    attr_reader :capacity

    # @param secret_key [String] a server-only key, +fly_sk_{environment}_…+
    # @param client_ip [#call] resolves the visitor's address from a
    #   {ProxyRequest}, exactly as for {Proxy}: read it from a header your own
    #   infrastructure sets, or {ProxyRequest#peer_host}. Never use the
    #   left-most +X-Forwarded-For+ value: the visitor writes it. A request
    #   whose address cannot be resolved is not reported.
    # @param capacity [Integer] the most answers remembered; a value above
    #   {MAX_CAPACITY} is read as {MAX_CAPACITY}
    # @param endpoint [String, nil] overrides the Fingerly API origin
    # @param allow_insecure_loopback [Boolean] lets +endpoint+ be plain +http+
    #   on a loopback host, for development and tests
    # @param configure_http [Proc, nil] receives the +Net::HTTP+ before it
    #   connects
    # @param logger [#warn, nil] receives the few lines this writes; standard
    #   error without one
    # @raise [ConfigurationError] for an invalid key, callback or option
    def initialize(secret_key:, client_ip:, capacity: DEFAULT_CAPACITY, endpoint: nil,
                   allow_insecure_loopback: false, configure_http: nil, logger: nil, clock: nil)
      raise ConfigurationError, "client_ip is required" unless client_ip.respond_to?(:call)
      unless capacity.is_a?(Integer) && capacity.positive?
        raise ConfigurationError, "capacity must be a positive Integer"
      end
      if logger && !logger.respond_to?(:warn)
        raise ConfigurationError, "logger must respond to warn"
      end

      @client = Client.new(secret_key: secret_key, endpoint: endpoint, timeout: FLUSH_DEADLINE,
                           configure_http: configure_http,
                           allow_insecure_loopback: allow_insecure_loopback)
      @capacity = [capacity, MAX_CAPACITY].min
      @logger = logger
      @reader = Reader.new(client_ip, ->(line) { log_limited(:client_ip, line) })
      # Only answers, pending reports and log limits age by this clock; waits
      # use the real one.
      @clock = clock || -> { AgentSightings.monotonic }
      @lock = Mutex.new
      @changed = ConditionVariable.new
      @cache = AnswerCache.new(@capacity)
      @buffer = PendingBuffer.new(MAX_PENDING, MAX_COUNT)
      @dropped = 0
      @in_flight = false
      @paused_until = nil
      @backoff = nil
      @log_lock = Mutex.new
      @logged_at = {}
      @closed = false
      @thread = nil
      @pid = Process.pid
    end

    # The server's last answer for this request, from memory only.
    #
    # Never waits on the network and never raises.
    #
    # @param request [Hash, #env] the Rack environment, or a request object
    #   that holds one, such as +Rack::Request+ or a Rails +request+
    # @return [AgentSighting] the answer, or {UNKNOWN}: serve the request as
    #   usual
    def lookup(request)
      sighting = @reader.sighting(request)
      return UNKNOWN if sighting.nil?

      @lock.synchronize do
        forked!
        @cache.get(sighting.key, now)
      end || UNKNOWN
    rescue StandardError
      UNKNOWN
    end

    # Records one served request for the next report. {Middleware} calls it
    # for the responses in its scope; call it yourself only from a framework
    # Rack does not reach.
    #
    # In memory only: never waits on the network and never raises.
    #
    # @param request [Hash, #env] the Rack environment, or a request object
    #   that holds one
    # @return [nil]
    def report(request)
      return nil if @closed

      sighting = @reader.sighting(request)
      return nil if sighting.nil?

      @lock.synchronize do
        forked!
        start_flusher
        @dropped += 1 if @buffer.add(sighting, now) == :dropped
        @changed.broadcast if full?
      end
      nil
    rescue StandardError
      nil
    end

    # Sends what is pending now, on the calling thread, and waits for it.
    #
    # For serverless runtimes, before an invocation ends; long-running servers
    # need not call it. Sends nothing while reporting is paused by a refusal.
    # Never raises, and works from a signal handler too.
    #
    # @return [nil]
    def flush
      return AgentSightings.outside_trap(locks) { flush } if AgentSightings.trap_context?

      loop do
        outcome = await_idle(AgentSightings.monotonic + IN_FLIGHT_WAIT) ? flush_once : :failed
        # The background thread took a batch after the wait: wait for it too.
        next if outcome == :busy
        break unless outcome == :sent
        break if @lock.synchronize { @buffer.empty? }
      end
      nil
    rescue StandardError
      nil
    end

    # Stops the background thread, then flushes what is pending as {#flush}
    # does, unless reporting is paused. Later reports are ignored; {#lookup}
    # keeps answering from memory. Safe to call more than once, from several
    # threads at once, and from a signal handler such as +trap("TERM")+,
    # which it holds up {TRAP_WAIT} seconds at most.
    #
    # @return [nil]
    def close
      return AgentSightings.outside_trap(locks) { close } if AgentSightings.trap_context?

      thread = @lock.synchronize do
        forked!
        @closed = true
        @changed.broadcast
        @thread
      end
      thread&.join(FLUSH_DEADLINE + 1)
      flush
    rescue StandardError
      nil
    end

    # @return [Integer] requests not reported because the pending buffer was
    #   full, in this process
    def dropped_count
      @lock.synchronize do
        forked!
        @dropped
      end
    end

    private

    def redacted_fields
      [["capacity", @capacity], ["secret_key", Redacted::MARK]]
    end

    def now = @clock.call

    # A forked child starts over: its parent reports what was pending, and
    # the parent's thread does not exist here. Remembered answers stay valid.
    def forked!
      return if @pid == Process.pid

      @pid = Process.pid
      @buffer.clear
      @dropped = 0
      @in_flight = false
      @thread = nil
      @log_lock = Mutex.new
      @logged_at = {}
    end

    def start_flusher
      return if @closed || @thread&.alive?

      @thread = Thread.new { run_flusher }
      @thread.name = "fingerly-agent-sightings"
      @thread.report_on_exception = false
    end

    def run_flusher
      loop do
        @lock.synchronize do
          @changed.wait(@lock, TICK) unless @closed || due?
        end
        return if @closed

        loop { break unless @lock.synchronize { due? } && flush_once == :sent }
      rescue StandardError
        # A bug here must not end reporting for the life of the process.
        sleep TICK
      end
    end

    def full?
      @buffer.size >= FLUSH_ITEMS || @buffer.bytes >= FLUSH_BYTES
    end

    def paused?
      !@paused_until.nil? && now < @paused_until
    end

    def due?
      return false if @buffer.empty? || paused?

      full? || now - @buffer.oldest_at >= FLUSH_AFTER
    end

    # Waits until no flush is in flight.
    #
    # @return [Boolean] false when the deadline passed first
    def await_idle(deadline)
      @lock.synchronize do
        forked!
        while @in_flight
          left = deadline - AgentSightings.monotonic
          return false if left <= 0

          @changed.wait(@lock, [left, TICK].min)
        end
        true
      end
    end

    # Sends one batch, unless another flush is in flight, nothing is
    # pending, or reporting is paused.
    #
    # @return [Symbol] +:sent+, +:failed+, +:busy+ or +:idle+
    def flush_once
      batch = @lock.synchronize do
        forked!
        return :busy if @in_flight
        return :idle if @buffer.empty? || paused?

        @in_flight = true
        @buffer.take(FLUSH_ITEMS, FLUSH_BYTES)
      end
      begin
        deliver(batch)
      ensure
        @lock.synchronize do
          # A kept batch was restored already; this settles the others.
          @buffer.settle(batch)
          @in_flight = false
          @changed.broadcast
        end
      end
    end

    # Sends a batch and applies the failure table of section 6.
    def deliver(batch)
      inputs = batch.map { |item| AgentSightingInput.new(**item.fields, count: item.hits) }
      answer = @client.agents.report_sightings(inputs)
      if answer.items.size != batch.size
        return drop("the API answered a report with the wrong number of items")
      end

      accepted(batch, answer)
    rescue APIError => e
      refused(e, batch)
    rescue TimeoutError => e
      # Once connected, the server may have counted the batch, and a retry
      # would count it twice. Before that, nothing was sent.
      e.connected? ? drop("a report timed out after it was sent") : keep(batch)
    rescue ConnectionError => e
      # A connection lost once the whole request was written is a timeout
      # after sending by another name: the server may have counted it.
      e.sent? ? drop("a report's connection failed after it was sent") : keep(batch)
    rescue StandardError
      drop("the API answered a report with a body that could not be read")
    end

    def accepted(batch, answer)
      @lock.synchronize do
        @cache.store(answer.rules_version,
                     batch.zip(answer.items).map { |item, sighting| [item.key, sighting] }, now)
        @backoff = nil
      end
      :sent
    end

    def refused(error, batch)
      case error.status
      when 429
        pause(AgentSightings.rate_limit_pause(error))
        restore(batch)
      when 401, 403
        pause(AUTH_PAUSE)
        log_limited(:auth, "fingerly agent sightings: the API refused the secret key " \
                           "(#{error.status}); the batch was dropped and reporting stops for " \
                           "#{AUTH_PAUSE} seconds")
      when 503 then keep(batch)
      else drop("the API refused a report (#{error.status})")
      end
      :failed
    end

    # Puts the batch back and backs off: nothing was counted.
    def keep(batch)
      @lock.synchronize do
        @backoff = @backoff ? [@backoff * 2, BACKOFF_MAX].min : BACKOFF_MIN
        @paused_until = now + @backoff
      end
      restore(batch)
      :failed
    end

    # The buffer's bound counts the batch in flight, so it always fits back.
    def restore(batch)
      @lock.synchronize { @buffer.restore(batch) }
    end

    def pause(seconds)
      @lock.synchronize { @paused_until = now + seconds }
    end

    # A batch that sending again cannot help, or that may already count.
    def drop(reason)
      log_limited(:drop, "fingerly agent sightings: #{reason}; the batch was dropped")
      :failed
    end

    # Logs a line at most once a minute for each kind. No line carries a
    # request's fields.
    def log_limited(kind, line)
      at = now
      due = @log_lock.synchronize do
        last = @logged_at[kind]
        next false if last && at - last < LOG_INTERVAL

        @logged_at[kind] = at
      end
      log("#{line} (logged at most once a minute)") if due
    end

    def log(line)
      @logger ? @logger.warn(line) : warn(line)
    rescue *Config::CALLBACK_ERRORS
      nil
    end
  end
end
