require 'rack'
require 'puma'
require 'rack/handler/puma'

class PatronTestServer
  APP = Rack::Builder.new { eval(File.read(__dir__ + '/config.ru')) }

  def self.start(ssl = false, port = 9001 )
    @ssl = ssl
    keypath = File.expand_path(__dir__ + '/../certs/privkey.pem')
    certpath = File.expand_path(__dir__ + '/../certs/cacert.pem')

    host = if ssl
      'ssl://127.0.0.1:%d?key=%s&cert=%s' % [port, keypath, certpath]
    else
      'tcp://127.0.0.1:%d' % port
    end
    $stderr.puts host.inspect
    Rack::Handler::Puma.run(APP, {:Port => port.to_i, :Verbose => true, :Host => '0.0.0.0'}) {|server|
      # @server = server
    }
  end
end
