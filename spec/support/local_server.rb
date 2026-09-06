# frozen_string_literal: true

require "socket"

# A minimal HTTP/1.1 server for the handful of behaviours WebMock cannot model:
# socket reuse and Content-Encoding negotiation, both of which happen inside
# Net::HTTP itself.
#
# Serves one canned response to every request and counts the TCP connections it
# accepted, which is what "keep-alive works" actually means.
class LocalServer
  attr_reader :port

  def initialize(body:, status: "200 OK", headers: {})
    @body = body
    @status = status
    @headers = { "Content-Type" => "application/json" }.merge(headers)
    @connections = 0
    @mutex = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { accept_loop }
  end

  def connections = @mutex.synchronize { @connections }

  def base_url = "http://127.0.0.1:#{port}"

  def stop
    @thread.kill
    @server.close
  end

  def self.run(**options)
    server = new(**options)
    yield server
  ensure
    server&.stop
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      @mutex.synchronize { @connections += 1 }
      Thread.new(socket) { |s| serve(s) }
    end
  rescue IOError, Errno::EBADF
    nil # stopped
  end

  def serve(socket)
    loop do
      request = read_request(socket)
      break if request.nil?

      socket.write(response)
    end
    socket.close
  rescue Errno::EPIPE, Errno::ECONNRESET, IOError
    nil
  end

  # Requests here are always bodyless GETs, so the headers are the whole thing.
  def read_request(socket)
    lines = []
    while (line = socket.gets)
      break if line == "\r\n"

      lines << line
    end
    lines.empty? ? nil : lines
  end

  def response
    head = @headers.merge("Content-Length" => @body.bytesize.to_s)
                   .map { |k, v| "#{k}: #{v}\r\n" }
                   .join
    "HTTP/1.1 #{@status}\r\n#{head}\r\n#{@body}"
  end
end
