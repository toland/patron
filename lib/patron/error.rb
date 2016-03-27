## -------------------------------------------------------------------
##
## Patron HTTP Client: Error definitions
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

module Patron

  # Base class for Patron exceptions.
  class Error < StandardError; end

  # Gets raised when tThe URL you passed to Patron used a protocol that it does not support.
  # This most likely the result of a misspelled protocol string.
  class UnsupportedProtocol   < Error; end

  # Gets raised when the URL was not properly formatted.
  class URLFormatError        < Error; end

  # Gets raised when the remote host name could not be resolved.
  class HostResolutionError   < Error; end

  # Gets raised when failing to connect to the remote host.
  class ConnectionFailed      < Error; end

  # Gets raised when the response was shorter or larger than expected.
  # This happens when the server first reports an expected transfer size,
  # and then delivers data that doesn't match the previously given size.
  class PartialFileError      < Error; end

  # Gets raised on an operation timeout. The specified time-out period was reached.
  class TimeoutError          < Error; end

  # Gets raised on too many redirects. When following redirects, Patron hit the maximum amount.
  class TooManyRedirects      < Error; end

end
