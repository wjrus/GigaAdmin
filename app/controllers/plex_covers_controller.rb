require "net/http"
require "uri"

class PlexCoversController < ApplicationController
  class InvalidCover < StandardError; end
  Cover = Data.define(:body, :content_type)
  MAX_COVER_BYTES = 10.megabytes
  METADATA_IMAGE_PATH = %r{\A/library/metadata/\d+/(?:thumb|art|banner)(?:/\d+)?\z}

  def show
    uri = cover_uri
    cover = fetch_cover(uri)
    expires_in 1.hour, public: false
    send_data cover.body, type: cover.content_type, disposition: "inline"
  rescue InvalidCover, Plex::ConfigurationError, URI::InvalidURIError
    head :not_found
  rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError
    head :bad_gateway
  end

  private

  def cover_uri
    path = URI(params.require(:path).to_s)
    raise InvalidCover if path.absolute? || path.host || path.fragment
    raise InvalidCover unless metadata_image_path?(path.path) || path.path == "/photo/:/transcode"

    base_url = ENV["PLEX_SERVER_BASE_URL"].to_s.delete_suffix("/")
    token = ENV["PLEX_TOKEN"].to_s
    raise Plex::ConfigurationError, "Missing PLEX_SERVER_BASE_URL" if base_url.blank?
    raise Plex::ConfigurationError, "Missing PLEX_TOKEN" if token.blank?

    uri = URI("#{base_url}#{path}")
    query = URI.decode_www_form(uri.query.to_s)
    validate_transcode_source!(query, uri) if path.path == "/photo/:/transcode"
    query.reject! { |key, _value| key.casecmp?("X-Plex-Token") }
    query << [ "X-Plex-Token", token ]
    uri.query = URI.encode_www_form(query)
    uri
  end

  def metadata_image_path?(path)
    METADATA_IMAGE_PATH.match?(path)
  end

  def validate_transcode_source!(query, server_uri)
    sources = query.select { |key, _value| key.casecmp?("url") }
    raise InvalidCover unless sources.one?

    source = URI(sources.first.last)
    if source.absolute?
      same_server = source.scheme == server_uri.scheme && source.host == server_uri.host && source.port == server_uri.port
      raise InvalidCover unless same_server && source.userinfo.nil?
    else
      raise InvalidCover if source.host
    end
    raise InvalidCover if source.fragment || source.query || !metadata_image_path?(source.path)

    # Plex's transcoder can itself fetch URLs. Restrict it to local metadata art.
    sources.first.replace([ "url", source.path ])
  end

  def valid_cover_headers?(response)
    return false unless response.is_a?(Net::HTTPSuccess)
    return false if response["Content-Length"].to_i > MAX_COVER_BYTES

    content_type = response["Content-Type"].to_s.split(";", 2).first.downcase
    content_type.start_with?("image/") && content_type != "image/svg+xml"
  end

  def fetch_cover(uri)
    Net::HTTP.start(
      uri.hostname,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: 5,
      read_timeout: 10,
      write_timeout: 10
    ) do |http|
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
      http.request(request) do |response|
        raise InvalidCover unless valid_cover_headers?(response)

        body = +"".b
        response.read_body do |chunk|
          raise InvalidCover if body.bytesize + chunk.bytesize > MAX_COVER_BYTES

          body << chunk
        end
        return Cover.new(body: body, content_type: response["Content-Type"])
      end
    end
  end
end
