# frozen_string_literal: true

module Patron

  # The HTTP verb methods, shared by Session and Multi. Every one of them ends in #request
  # or #stream, which the including class defines: a Session performs the request and returns
  # the Response, a Multi starts it and returns the Transfer.
  module Verbs

    # Retrieve the contents of the specified `url` optionally sending the
    # specified headers. If the +base_url+ varaible is set then it is prepended
    # to the +url+ parameter. Any custom headers are merged with the contents
    # of the +headers+ instance variable. The results are returned in a
    # Response object.
    # Notice: this method doesn't accept any `data` argument: if you need to send a request body
    # with a GET request, when using ElasticSearch for example, please, use the #request method.
    #
    # @param url[String] the URL to fetch
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def get(url, headers = {})
      request(:get, url, headers)
    end

    # Same as #get but performs a HEAD request.
    #
    # @see #get
    # @param url[String] the URL to fetch
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def head(url, headers = {})
      request(:head, url, headers)
    end

    # Same as #get but performs a DELETE request.
    #
    # Notice: this method doesn't accept any `data` argument: if you need to send data with
    # a delete request (as might be needed for ElasticSearch), please, use the #request method.
    #
    # @param url[String] the URL to fetch
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def delete(url, headers = {})
      request(:delete, url, headers)
    end

    # Uploads the passed `data` to the specified `url` using an HTTP PUT. Note that
    # unline ++post++, a Hash is not accepted as the ++data++ argument.
    #
    # @param url[String] the URL to fetch
    # @param data[#to_s, #to_path, #read] an object that can be converted to a String
    #   to create the request body, that responds to #to_path to upload the entire request body
    #   from that file, or that responds to #read to stream the body from it
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def put(url, data, headers = {})
      request(:put, url, headers, data: data)
    end

    # Uploads the passed `data` to the specified `url` using an HTTP PATCH. Note that
    # unline ++post++, a Hash is not accepted as the ++data++ argument.
    #
    # @param url[String] the URL to fetch
    # @param data[#to_s, #to_path, #read] an object that can be converted to a String
    #   to create the request body, that responds to #to_path to upload the entire request body
    #   from that file, or that responds to #read to stream the body from it
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def patch(url, data, headers = {})
      request(:patch, url, headers, data: data)
    end

    # Uploads the contents of `file` to the specified `url` using an HTTP PUT. The file will be
    # sent "as-is" without any multipart encoding.
    #
    # @param url[String] the URL to fetch
    # @param filename[String] path to the file to be uploaded
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def put_file(url, filename, headers = {})
      request(:put, url, headers, file: filename)
    end

    # Uploads the passed `data` to the specified `url` using an HTTP POST.
    #
    # @param url[String] the URL to fetch
    # @param data[Hash, #to_s, #to_path, #read] a Hash of form fields/values,
    #   or an object that can be converted to a String to create the request body,
    #   or an object that responds to #to_path to upload the entire request body from that file,
    #   or an object that responds to #read to stream the body from it
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def post(url, data, headers = {})
      data, headers = form_encode(data, headers)
      request(:post, url, headers, data: data)
    end

    # Uploads the contents of `file` to the specified `url` using an HTTP POST.
    # The file will be sent "as-is" without any multipart encoding.
    #
    # @param url[String] the URL to fetch
    # @param filename[String] path to the file to be uploaded
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def post_file(url, filename, headers = {})
      request(:post, url, headers, file: filename)
    end

    # Uploads the contents of `filename` to the specified `url` using an HTTP POST,
    # in combination with given form fields passed in `data`.
    #
    # @param url[String] the URL to fetch
    # @param data[Hash] hash of the form fields
    # @param filename[String] path to the file to be uploaded
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def post_multipart(url, data, filename, headers = {})
      request(:post, url, headers, data: data, file: filename, multipart: true)
    end

    # @!group WebDAV methods
    # Sends a WebDAV COPY request to the specified +url+.
    #
    # @param url[String] the URL to copy
    # @param dest[String] the URL of the COPY destination
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def copy(url, dest, headers = {})
      request(:copy, url, headers.merge('Destination' => dest))
    end
    # @!endgroup

    # @!group Streaming
    # Same as #stream with a GET
    #
    # @param url[String] the URL to fetch
    # @param headers[Hash] the hash of header keys to values
    # @param options[Hash] the same options as #request takes
    # @yieldparam stream [Patron::ResponseStream]
    # @return [Patron::TransferStats]
    def get_stream(url, headers = {}, **options, &block)
      stream(:get, url, headers, **options, &block)
    end

    # Same as #stream with a PUT, sending `data` like #put does
    #
    # @param url[String] the URL for the request
    # @param data[#to_s, #to_path, #read] the request body, see #put
    # @param headers[Hash] the hash of header keys to values
    # @param options[Hash] the same options as #request takes
    # @yieldparam stream [Patron::ResponseStream]
    # @return [Patron::TransferStats]
    def put_stream(url, data, headers = {}, **options, &block)
      stream(:put, url, headers, **options, data: data, &block)
    end

    # Same as #stream with a POST, sending `data` like #post does: a Hash is form-encoded
    #
    # @param url[String] the URL for the request
    # @param data[Hash, #to_s, #to_path, #read] the request body, see #post
    # @param headers[Hash] the hash of header keys to values
    # @param options[Hash] the same options as #request takes
    # @yieldparam stream [Patron::ResponseStream]
    # @return [Patron::TransferStats]
    def post_stream(url, data, headers = {}, **options, &block)
      data, headers = form_encode(data, headers)
      stream(:post, url, headers, **options, data: data, &block)
    end

    # Same as #stream with a PATCH, sending `data` like #patch does
    #
    # @param url[String] the URL for the request
    # @param data[#to_s, #to_path, #read] the request body, see #patch
    # @param headers[Hash] the hash of header keys to values
    # @param options[Hash] the same options as #request takes
    # @yieldparam stream [Patron::ResponseStream]
    # @return [Patron::TransferStats]
    def patch_stream(url, data, headers = {}, **options, &block)
      stream(:patch, url, headers, **options, data: data, &block)
    end
    # @!endgroup

    private

    def form_encode(data, headers)
      return [data, headers] unless data.is_a?(Hash)
      encoded = data.map { |k, v| Session.escape(k.to_s) + '=' + Session.escape(v.to_s) }.join('&')
      [encoded, headers.merge('Content-Type' => 'application/x-www-form-urlencoded')]
    end
  end
end
