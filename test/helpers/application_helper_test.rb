require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "localized time formats include the year" do
    time = Time.zone.local(2026, 5, 24, 13, 45, 0)

    assert_equal "May 24, 2026 13:45", l(time, format: :short)
    assert_equal "May 24, 2026 13:45", l(time, format: :long)
  end

  test "plex timestamps include the year" do
    timestamp = Time.zone.local(2026, 5, 24, 13, 45, 0).to_i

    assert_equal "May 24, 2026 13:45", plex_timestamp(timestamp)
  end

  test "cover paths and absolute HTTP URLs use the authenticated local proxy" do
    [ "/library/metadata/42/thumb/123", "library/metadata/42/thumb/123",
      "https://plex.example.test:32400/library/metadata/42/thumb/123" ].each do |source|
      url = URI(plex_image_url(source))

      assert_nil url.host
      assert_equal "/plex_cover", url.path
      assert_equal "/library/metadata/42/thumb/123", URI.decode_www_form(url.query).to_h.fetch("path")
    end
  end

  test "cover URLs never publish Plex tokens supplied in metadata" do
    url = plex_image_url("https://plex.example.test/library/metadata/42/thumb?x-plex-token=private-token&width=200")

    assert_not_includes url, "private-token"
    assert_equal "/library/metadata/42/thumb?width=200", URI.decode_www_form(URI(url).query).to_h.fetch("path")
  end

  test "unsupported or malformed cover URIs do not break the page" do
    [ nil, "", "data:image/png;base64,AAA", "mailto:admin@example.test", "file:///tmp/image.jpg",
      "//other.example.test/library/metadata/42/thumb", "http:/library/metadata/42/thumb",
      "/library/metadata/42/thumb#fragment", "https://[invalid" ].each do |source|
      assert_nil plex_image_url(source), "Accepted unsupported cover URI #{source.inspect}"
    end
  end
end
