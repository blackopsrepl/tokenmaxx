# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module TokenMaxx
  module Core
    module Http
      Response = Struct.new(:status, :body, :headers, keyword_init: true)

      module_function

      def request(method, url, headers: {}, json: nil, form: nil, open_timeout: 10, read_timeout: 30)
        uri = URI(url)
        request = request_class(method).new(uri)
        headers.each { |key, value| request[key] = value }

        if json
          request["Content-Type"] ||= "application/json"
          request.body = JSON.generate(json)
        elsif form
          request["Content-Type"] ||= "application/x-www-form-urlencoded"
          request.body = URI.encode_www_form(form)
        end

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.open_timeout = open_timeout
          http.read_timeout = read_timeout
          http.max_retries = 0
          response = http.request(request)
          Response.new(status: response.code.to_i, body: response.body.to_s, headers: response.each_header.to_h)
        end
      end

      def parse_json(response)
        JSON.parse(response.body, symbolize_names: true)
      rescue JSON::ParserError
        {}
      end

      def request_class(method)
        case method.to_s.upcase
        when "GET" then Net::HTTP::Get
        when "POST" then Net::HTTP::Post
        when "PUT" then Net::HTTP::Put
        when "PATCH" then Net::HTTP::Patch
        when "DELETE" then Net::HTTP::Delete
        else
          raise ArgumentError, "Unsupported HTTP method: #{method}"
        end
      end
    end
  end
end
