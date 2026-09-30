require "test_helper"

class ActivityChartsHelperTest < ActionView::TestCase
  include ActivityChartsHelper

  test "separates SVG line segments across unobserved buckets and labels observations" do
    chart = Struct.new(:points) do
      def peak(key)
        points.filter_map { |point| point[key] }.max
      end
    end.new([
      { at: Time.utc(2026, 9, 29, 12), total: 0, samples: 1 },
      { at: Time.utc(2026, 9, 29, 12, 10), total: nil, samples: 0 },
      { at: Time.utc(2026, 9, 29, 12, 20), total: 4, samples: 10 }
    ])
    html = activity_chart_svg(chart, series: { total: { label: "All streams", color: "#67e8f9" } }, unit: "streams", title: "Concurrency")
    document = Nokogiri::HTML.fragment(html)
    assert_equal 2, document.css("polyline").size
    assert_equal 2, document.css("circle").size
    assert_equal "img", document.at_css("svg")["role"]
    assert_includes document.css("circle title").map(&:text), "Sep 29 12:00 UTC: All streams 0 streams; 1 polls"
  end
end
