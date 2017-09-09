module Patron

  # Base class for Patron exceptions.
  class Error < StandardError; end

  # Gets raised when the URL passed to Patron used a protocol that it does not support.
  # This most likely the result of a misspelled protocol string.
  class UnsupportedProtocol    < Error; end

  # Gets raised when a request is attempted with an unsupported SSL version.
  class UnsupportedSSLVersion  < Error; end

  # Gets raised when a request is attempted with an unsupported HTTP version.
  class UnsupportedHTTPVersion  < Error; end

  # Gets raised when the URL was not properly formatted.
  class URLFormatError         < Error; end

  # Gets raised when the remote host name could not be resolved.
  class HostResolutionError    < Error; end

  # Gets raised when failing to connect to the remote host.
  class ConnectionFailed       < Error; end

  # Gets raised when the response was shorter or larger than expected.
  # This happens when the server first reports an expected transfer size,
  # and then delivers data that doesn't match the previously given size.
  class PartialFileError       < Error; end

  # Gets raised on an operation timeout. The specified time-out period was reached.
  class TimeoutError           < Error; end

  # Gets raised on too many redirects. When following redirects, Patron hit the maximum amount.
  class TooManyRedirects       < Error; end

  # Gets raised if the progress callback, or an interrupt, aborts the Curl perform() call
  class Aborted                < Error; end

  # Gets raised when the server specifies an encoding that could not be found, or has an invalid name,
  # or when the server "lies" about the encoding of the response body (such as can be the case
  # when the server specifies an encoding in `Content-Type`) which the HTML generator then overrides
  # with a `meta` element.
  class HeaderCharsetInvalid < Error; end
  
  # Gets raised when you try to use `decoded_body` but it can't
  # be represented by your Ruby process's current internal encoding
  class NonRepresentableBody < HeaderCharsetInvalid; end
end
