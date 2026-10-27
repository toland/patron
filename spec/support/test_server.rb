# frozen_string_literal: true

require 'rack'
require 'puma'
require 'rack/handler/puma'

class PatronTestServer
  CONFIG_RU = File.join(__dir__, 'config.ru')
  APP = Rack::Builder.new_from_string(File.read(CONFIG_RU), CONFIG_RU)

  def self.start(ssl = false, port = 9001, client_ca: nil)
    # Reset the RSpec's SIGINT handler that does not really terminate after
    # the first Ctrl+C pressed.
    # Useful to terminate the forked process before Puma is actually started:
    # it happens when running one particular example that does not need Puma
    # so the specs are in fact finished before the Puma started.
    Signal.trap('INT', 'EXIT')
    @ssl = ssl
    keypath = File.join(__dir__, 'certs', 'privkey.pem')
    certpath = File.join(__dir__, 'certs', 'cacert.pem')

    host = if ssl && client_ca
      # force_peer makes Puma drop the handshake when no valid client certificate is presented
      'ssl://0.0.0.0:%d?key=%s&cert=%s&ca=%s&verify_mode=force_peer' % [port, keypath, certpath, client_ca]
    elsif ssl
      'ssl://0.0.0.0:%d?key=%s&cert=%s' % [port, keypath, certpath]
    else
      '0.0.0.0'
    end
    Rack::Handler::Puma.run(APP, :Port => port.to_i, :Verbose => true, :Host => host)
  end
end
