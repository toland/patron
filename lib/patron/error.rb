
module Patron

  # Base class for Patron exceptions.
  class Error < StandardError; end

  # The URL you passed to Patron used a protocol that it does not support.
  # This most likely the result of a misspelled protocol string.
  class UnsupportedProtocol   < Error; end

  # The URL was not properly formatted.
  class URLFormatError        < Error; end

  # Could not resolve the remote host name.
  class HostResolutionError   < Error; end

  # Failed to connect to the remote host.
  class ConnectionFailed      < Error; end

  # A file transfer was shorter or larger than expected.
  # This happens when the server first reports an expected transfer size,
  # and then delivers data that doesn't match the previously given size.
  class PartialFileError      < Error; end

  # Operation timeout. The specified time-out period was reached.
  class TimeoutError          < Error; end

  # Too many redirects. When following redirects, Patron hit the maximum amount.
  class TooManyRedirects      < Error; end

end
