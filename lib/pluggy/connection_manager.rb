# frozen_string_literal: true

require "net/http"
require "openssl"

module Pluggy
  # Keep-alive Net::HTTP pool, one instance per thread (Net::HTTP objects are
  # not thread-safe), keyed by Configuration#connection_key.
  #
  # After a fork, sockets inherited from the parent are unusable. Call
  # Pluggy::ConnectionManager.current.clear! in your after_fork hook
  # (Puma, Unicorn, Sidekiq).
  class ConnectionManager
    def self.current
      Thread.current[:pluggy_connection_manager] ||= new
    end

    def initialize
      @pool = {}
    end

    def connection_for(config)
      http = @pool[config.connection_key] ||= build(config)
      # Net::HTTP only reuses a socket once the session has been started; an
      # unstarted object opens and closes one connection per request.
      http.start unless http.started?
      http
    end

    def clear!
      @pool.each_value do |http|
        http.finish if http.started?
      rescue IOError, SystemCallError
        # Already dead; nothing to close.
      end
      @pool.clear
    end

    private

    def build(config)
      uri = config.uri
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = config.verify_ssl_certs ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
      http.open_timeout = config.open_timeout
      http.read_timeout = config.read_timeout
      http.write_timeout = config.write_timeout
      http.keep_alive_timeout = 30
      http
    end
  end
end
