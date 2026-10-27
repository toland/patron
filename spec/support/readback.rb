# frozen_string_literal: true

require 'json'

# The test server echoes the request it received as JSON, and the specs assert on it
# through this little value object. The body travels base64-encoded since it may be binary
module Readback
  Request = Data.define(:fullpath, :path, :query_string, :request_method, :header, :body, :content_type) do
    def [](key) = public_send(key)
  end

  def readback(json)
    attrs = JSON.parse(json)
    body = attrs['body_base64']&.unpack1('m0')
    Request.new(
      fullpath: attrs['fullpath'],
      path: attrs['path'],
      query_string: attrs['query_string'],
      request_method: attrs['request_method'],
      header: attrs['header'],
      body: body,
      content_type: attrs['content_type']
    )
  end
end

RSpec.configure { |c| c.include Readback }
