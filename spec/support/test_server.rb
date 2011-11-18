## -------------------------------------------------------------------
##
## Patron HTTP Client: HTTP test server for integration tests
## Copyright (c) 2008 The Hive http://www.thehive.com/
##
## Permission is hereby granted, free of charge, to any person obtaining a copy
## of this software and associated documentation files (the "Software"), to deal
## in the Software without restriction, including without limitation the rights
## to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
## copies of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:
##
## The above copyright notice and this permission notice shall be included in
## all copies or substantial portions of the Software.
##
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
## IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
## FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
## AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
## LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
## OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
## THE SOFTWARE.
##
## -------------------------------------------------------------------
require 'yaml'
require 'webrick'
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

class TimeoutServlet < HTTPServlet::AbstractServlet
  def do_GET(req,res)
    sleep(1.1)
  end
end

class RedirectServlet < HTTPServlet::AbstractServlet
  def do_GET(req,res)
    res['Location'] = "http://localhost:9001/test"
    res.status = 301
  end
end


class TestPostBodyServlet < HTTPServlet::AbstractServlet
  include RespondWith
  def do_POST(req, res)
    respond_with(:POST, {'body' => req.body, 'content_type' => req.content_type}, res)
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

class PatronTestServer

  def self.start( log_file = nil )
    new(log_file).start
  end

  def initialize( log_file = nil )
    log_file ||= StringIO.new
    log = WEBrick::Log.new(log_file)

    @server = WEBrick::HTTPServer.new(
      :Port => 9001,
      :Logger => log,
      :AccessLog => [
          [ log, WEBrick::AccessLog::COMMON_LOG_FORMAT ],
          [ log, WEBrick::AccessLog::REFERER_LOG_FORMAT ]
       ]
    )
    @server.mount("/test", TestServlet)
    @server.mount("/testpost", TestPostBodyServlet)
    @server.mount("/timeout", TimeoutServlet)
    @server.mount("/redirect", RedirectServlet)
    @server.mount("/picture", PictureServlet)
    @server.mount("/setcookie", SetCookieServlet)
    @server.mount("/repetitiveheader", RepetitiveHeaderServlet)
    @server.mount("/wrongcontentlength", WrongContentLengthServlet)
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

