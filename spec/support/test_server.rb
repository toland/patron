require 'rack'
require 'puma'
require 'rack/handler/puma'

class PatronTestServer
  APP = Rack::Builder.new { eval(File.read(File.join(__dir__, 'config.ru'))) }

  def self.start(ssl = false, port = 9001 )
    @ssl = ssl
    keypath = File.join(__dir__, 'certs', 'privkey.pem')
    certpath = File.join(__dir__, 'certs', 'cacert.pem')

    host = if ssl
      'ssl://0.0.0.0:%d?key=%s&cert=%s' % [port, keypath, certpath]
    else
      '0.0.0.0'
    end
    Rack::Handler::Puma.run(APP, {:Port => port.to_i, :Verbose => true, :Host => host})
  end
end
