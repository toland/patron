## -------------------------------------------------------------------
##
## Patron HTTP Client: HTTP test server for integration tests

require 'yaml'
require 'webrick'
require 'webrick/https'
require 'openssl'
require 'zlib'

include WEBrick

# This ugly little hack is necessary to make the specs pass when running
# the test_server script under Ruby 1.9. URI::Parser#to_yaml generates
# regexp representations that YAML.parse cannot parse.
class URI::Parser
  def to_yaml(opts = {})
    {}.to_yaml(opts)
  end
end

module RespondWith
  def respond_with(method, req, res)
    res.body = req.to_yaml
    res['Content-Type'] = "text/plain"
  end
end

class TestServlet < HTTPServlet::AbstractServlet

  include RespondWith

  def do_GET(req,res)
    respond_with(:GET, req, res)
  end

  def do_POST(req,res)
    respond_with(:POST, req, res)
  end

  def do_PUT(req,res)
    respond_with(:PUT, req, res)
  end

  def do_DELETE(req,res)
    respond_with(:DELETE, req, res)
  end

  def do_COPY(req,res)
    respond_with(:COPY, req, res)
  end
end

class GzipServlet < HTTPServlet::AbstractServlet

  def do_GET(req,res)
    raise "Need to have the right Accept-Encoding: header" unless req.header['Accept-Encoding']
    
    out = StringIO.new
    z = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION)
    1024.times { 
      out << z.deflate('Some highly compressible data')
    }
    out << z.finish
    z.close
    
    content_length = out.size
    # Content-Length gets set automatically by WEBrick, and if we do it manually
    # here then two headers will be set.
    # res.header['Content-Length'] = content_length
    res.header['Content-Encoding'] = 'deflate'
    res.header['Vary'] = 'Accept-Encoding'
    res.body = out.string
  end
end

class TimeoutServlet < HTTPServlet::AbstractServlet
  def do_GET(req,res)
    sleep(1.1)
  end
end

class SlowServlet < HTTPServlet::AbstractServlet
  def do_GET(req,res)
    res.header['Content-Type'] = 'text/plain'
    res.body << 'x'
    sleep 20
    res.body << 'rest of body'
  end
end

class RedirectServlet < HTTPServlet::AbstractServlet
  def do_GET(req,res)
    res['Location'] = "http://localhost:9001/test"
    res.status = 301
  end
end

class EvilRedirectServlet < HTTPServlet::AbstractServlet
  def do_GET(req,res)
    res['Location'] = "smtp://mailbox:secret@localhost"
    res.status = 301
  end
end

class TestPostBodyServlet < HTTPServlet::AbstractServlet
  include RespondWith
  def do_POST(req, res)
    respond_with(:POST, {'body' => req.body, 'content_type' => req.content_type}, res)
  end
end

class TestPatchBodyServlet < HTTPServlet::AbstractServlet
  include RespondWith
  def do_PATCH(req, res)
    respond_with(:PATCH, {'body' => req.body, 'content_type' => req.content_type}, res)
  end
end

class SetCookieServlet < HTTPServlet::AbstractServlet
  def do_GET(req, res)
    res['Set-Cookie'] = "session_id=foo123"
    res['Location'] = "http://localhost:9001/test"
    res.status = 301
  end
end

class RepetitiveHeaderServlet < HTTPServlet::AbstractServlet
  def do_GET(req, res)
    # the only way to get webrick to output two headers with the same name is using cookies, so that's what we'll do:
    res.cookies << Cookie.new('a', '1')
    res.cookies << Cookie.new('b', '2')
    res['Content-Type'] = "text/plain"
    res.body = "Hi."
  end
end

class PictureServlet < HTTPServlet::AbstractServlet
  def do_GET(req, res)
    res['Content-Type'] = "image/png"
    res.body = File.read("./pic.png")
  end
end

class WrongContentLengthServlet < HTTPServlet::AbstractServlet
  def do_GET(req, res)
    res.keep_alive = false
    res.content_length = 1024
    res.body = "Hello."
  end
end

# Serves a substantial amount of data
class LargeServlet < HTTPServlet::AbstractServlet
  def do_GET(req, res)
    res.content_length = 15 * 1024 * 1024
    res.body = Random.new.bytes(15 * 1024 * 1024)
  end
end

class PatronTestServer

  def self.start( log_file = nil, ssl = false, port = 9001 )
    new(log_file, ssl, port).start
  end

  def initialize( log_file = nil, ssl = false, port = 9001 )
    log_file ||= StringIO.new
    log = WEBrick::Log.new(log_file)

    options = {
      :Port => port,
      :Logger => log,
      :AccessLog => [
          [ log, WEBrick::AccessLog::COMMON_LOG_FORMAT ],
          [ log, WEBrick::AccessLog::REFERER_LOG_FORMAT ]
       ]
    }

    if ssl
      options[:SSLEnable] = true
      options[:SSLCertificate] = OpenSSL::X509::Certificate.new(File.open("spec/certs/cacert.pem").read)
      options[:SSLPrivateKey] = OpenSSL::PKey::RSA.new(File.open("spec/certs/privkey.pem").read)
      options[:SSLCertName] = [ ["CN", WEBrick::Utils::getservername ] ]
    end

    @server = WEBrick::HTTPServer.new(options)

    @server.mount("/test", TestServlet)
    @server.mount("/testpost", TestPostBodyServlet)
    @server.mount("/testpatch", TestPatchBodyServlet)
    @server.mount("/timeout", TimeoutServlet)
    @server.mount("/slow", SlowServlet)
    @server.mount("/redirect", RedirectServlet)
    @server.mount("/evil-redirect", EvilRedirectServlet)
    @server.mount("/picture", PictureServlet)
    @server.mount("/very-large", LargeServlet)
    @server.mount("/setcookie", SetCookieServlet)
    @server.mount("/repetitiveheader", RepetitiveHeaderServlet)
    @server.mount("/wrongcontentlength", WrongContentLengthServlet)
    @server.mount("/gzip-compressed", GzipServlet)
  end

  def start
    trap('INT') {
      begin
        @server.shutdown unless @server.nil?
      rescue Object => e
        $stderr.puts "Error #{__FILE__}:#{__LINE__}\n#{e.message}"
      end
    }

    @thread = Thread.new { @server.start }
    Thread.pass
    self
  end

  def join
    if defined? @thread and @thread
      @thread.join
    end
    self
  end
end

