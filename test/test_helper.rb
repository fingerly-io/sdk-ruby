# frozen_string_literal: true

require "minitest/autorun"
require "webrick"
require "json"
require "socket"
require "fingerly"

# One request a fake API received, kept for assertions.
RecordedRequest = Struct.new(:request_method, :path, :raw_uri, :query, :headers, :body) do
  def header(name)
    headers[name.downcase]
  end
end

# A real HTTP server on a loopback port.
#
# The tests drive one of these rather than stubbing Net::HTTP. A stub shares
# the SDK's assumptions about framing, keep-alive, compression and stalled
# bodies, so it cannot disprove any of them.
class FakeAPI
  # @return [Array<RecordedRequest>] every request received, in order
  attr_reader :requests

  # @return [#call] what answers the next request
  attr_accessor :handler

  # @param handler [#call] receives (req, res); WEBrick writes what it sets
  def initialize(handler)
    @requests = []
    @mutex = Mutex.new
    @handler = handler
    @server = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1",
      Port: 0,
      # Without this WEBrick reverse-resolves the peer on every request, which
      # on a loopback socket is a second of nothing per test.
      DoNotReverseLookup: true,
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: []
    )
    @server.mount_proc("/") do |req, res|
      body = req.body.to_s
      @mutex.synchronize { @requests << record(req, body) }
      @handler.call(req, res)
    end
    @thread = Thread.new { @server.start }
  end

  # @return [String] the origin to point a client at
  def origin
    "http://127.0.0.1:#{@server.config[:Port]}"
  end

  def shutdown
    @server.shutdown
    # A test that deliberately stalled a response leaves a worker mid-write;
    # the process is ending anyway, so do not wait on it forever.
    @thread.join(5) || @thread.kill
  end

  def reset!
    @mutex.synchronize { @requests.clear }
  end

  # The one server every test shares.
  #
  # Starting WEBrick costs nothing but stopping it waits on any connection the
  # client is still holding open, which at one server per test was most of the
  # suite's runtime. One server, swapped handler, requests cleared.
  def self.shared
    @shared ||= begin
      api = new(->(_req, _res) { raise "no handler set" })
      Minitest.after_run { api.shutdown }
      api
    end
  end

  # Serves one handler for the duration of a block.
  def self.run(handler)
    api = shared
    api.handler = handler
    api.reset!
    yield api
  end

  # A handler that answers every request with one status and JSON body.
  def self.json(status, body)
    lambda do |_req, res|
      res.status = status
      res["content-type"] = "application/json"
      res.body = body
    end
  end

  private

  def record(req, body)
    headers = {}
    req.header.each { |name, values| headers[name.downcase] = Array(values).join(", ") }
    # req.path is already unescaped and normalised by WEBrick; unparsed_uri is
    # the request line exactly as it went over the wire, which is what an
    # escaping test has to look at.
    RecordedRequest.new(
      req.request_method, req.path, req.unparsed_uri, req.query_string, headers, body
    )
  end
end

# The vendored server contract snapshot.
#
# It keeps the test suite independent of sibling repositories. Refresh it with
# `ruby tools/sync_contract.rb`.
module Fixtures
  DIR = File.expand_path("../contract", __dir__)

  module_function

  def document
    @document ||= JSON.parse(File.read(File.join(DIR, "fixtures.json")))
  end

  def responses(schema)
    document.fetch("responses").select { |item| item["schema"] == schema }
  end

  def webhooks
    document.fetch("webhooks")
  end
end

# A raw socket server that answers with a status line and then one header
# line at a time, slowly, as a misbehaving upstream or middlebox might.
#
# WEBrick cannot do this: it writes the header block in one go. Net::HTTP
# reads each header line with its full read timeout, so this is what proves a
# deadline covers the headers and not only the body.
class TricklingServer
  def initialize(interval: 0.2, lines: 50)
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new do
      loop do
        socket = @server.accept
        Thread.new(socket) { |client| trickle(client, interval, lines) }
      end
    rescue IOError
      # Closed by #shutdown.
    end
  end

  def origin
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def shutdown
    @server.close
    @thread.join(1)
  end

  def self.run(**)
    server = new(**)
    yield server
  ensure
    server&.shutdown
  end

  private

  def trickle(client, interval, lines)
    head = +""
    head << client.readpartial(4096) until head.include?("\r\n\r\n")
    client.write("HTTP/1.1 200 OK\r\n")
    lines.times do |i|
      sleep interval
      client.write("x-pad-#{i}: a\r\n")
    end
    client.write("content-type: application/json\r\ncontent-length: 2\r\n\r\n{}")
  rescue IOError, SystemCallError
    # The client gave up, which is the point.
  ensure
    client.close
  end
end

# A raw socket server that reads one request and writes whatever bytes the
# test gives it, for responses no well-behaved server would send: a body cut
# short, a status line that is not one, a gzip body that is not gzip.
class RawServer
  def initialize(response)
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new do
      loop do
        client = @server.accept
        head = +""
        head << client.readpartial(4096) until head.include?("\r\n\r\n")
        client.write(response)
        client.close
      end
    rescue IOError, SystemCallError
      # Closed by #shutdown.
    end
  end

  def origin
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def self.run(response)
    server = new(response)
    yield server
  ensure
    server&.shutdown
  end

  def shutdown
    @server.close
    @thread.join(1)
  end
end
