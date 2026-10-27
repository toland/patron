# frozen_string_literal: true

require 'rack'
require 'rack/builder'
require 'puma'
require 'puma/server'
require 'puma/minissl'

class PatronTestServer
  CONFIG_RU = File.join(__dir__, 'config.ru')
  CERT_DIR = File.join(__dir__, 'certs')
  APP = Rack::Builder.new_from_string(File.read(CONFIG_RU), CONFIG_RU)

  def self.start(ssl = false, port = 9001, client_ca: nil)
    # Reset the RSpec's SIGINT handler that does not really terminate after
    # the first Ctrl+C pressed.
    # Useful to terminate the forked process before Puma is actually started:
    # it happens when running one particular example that does not need Puma
    # so the specs are in fact finished before the Puma started.
    Signal.trap('INT', 'EXIT')

    # COPY is not in Puma's default verb list, and the specs exercise it
    server = Puma::Server.new(APP, nil, min_threads: 0, max_threads: 5, supported_http_methods: :any)
    if ssl
      server.add_ssl_listener('0.0.0.0', port.to_i, ssl_context(client_ca))
    else
      server.add_tcp_listener('0.0.0.0', port.to_i)
    end
    server.run.join
  end

  def self.ssl_context(client_ca)
    ctx = Puma::MiniSSL::Context.new
    ctx.key = File.join(CERT_DIR, 'privkey.pem')
    ctx.cert = File.join(CERT_DIR, 'cacert.pem')
    if client_ca
      # force_peer makes Puma drop the handshake when no valid client certificate is presented
      ctx.ca = client_ca
      ctx.verify_mode = Puma::MiniSSL::VERIFY_PEER | Puma::MiniSSL::VERIFY_FAIL_IF_NO_PEER_CERT
    else
      ctx.verify_mode = Puma::MiniSSL::VERIFY_NONE
    end
    ctx
  end
end
