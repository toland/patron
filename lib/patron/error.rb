
module Patron

  class Error < StandardError; end

  class UnsupportedProtocol   < Error; end
  class URLFormatError        < Error; end
  class HostResolutionError   < Error; end
  class ConnectionFailed      < Error; end
  class PartialFileError      < Error; end
  class TimeoutError          < Error; end
  class TooManyRedirects      < Error; end

end
