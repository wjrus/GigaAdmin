require "test_helper"

class ActivityChartsHelperTest < ActionView::TestCase
  include ActivityChartsHelper

  test "separates SVG line segments across unobserved buckets and labels observations" do
    document = render_chart([ 0, nil, 4 ])
    assert_equal 2, document.css("path").size
    assert_equal 2, document.css("circle").size
    assert document.css("circle").all? { |circle| circle["opacity"] == "1" }
    assert document.css("path").all? { |path| path["d"].match?(/\AM [\d.,]+\z/) }
    assert_equal "img", document.at_css("svg")["role"]
    assert_includes document.css("circle title").map(&:text), "Sep 29 12:00 UTC: All streams 0 streams; 1 polls"
  end

  test "smooth curves pass through the original samples and keep their tooltips" do
    document = render_chart([ 0, 2, 8, 4, 0 ])
    path = document.at_css("path")
    curves = path["d"].scan(/C ([\d., -]+)/)

    assert_empty document.css("polyline")
    assert document.css("circle").all? { |circle| circle["opacity"] == "0" }
    assert_equal 4, curves.size
    assert_equal "round", path["stroke-linejoin"]
    document.css("circle").drop(1).zip(curves).each do |circle, (curve)|
      assert_equal [ circle["cx"].to_f, circle["cy"].to_f ], curve.split.last.split(",").map(&:to_f)
    end
    assert_includes document.css("circle title").map(&:text), "Sep 29 12:20 UTC: All streams 8 streams; 1 polls"
  end

  test "curves stay within adjacent sample values even around spikes plateaus and zeroes" do
    [ [ 0, 10, 0, 0, 10, 10, 0 ], [ 0, 1, 9, 10, 9, 1, 0 ], [ 3, 3, 3 ], [ 0, 0, 0 ] ].each do |values|
      document = render_chart(values)
      samples = document.css("circle").map { |circle| [ circle["cx"].to_f, circle["cy"].to_f ] }
      curves = document.at_css("path")["d"].scan(/C ([\d., -]+)/).map do |(curve)|
        curve.split.map { |pair| pair.split(",").map(&:to_f) }
      end
      samples.each_cons(2).zip(curves).each do |(start, finish), controls|
        # A Bezier curve stays inside the convex hull of its control points.
        controls.each do |x, y|
          assert_includes start[0]..finish[0], x
          assert_includes [ start[1], finish[1] ].min..[ start[1], finish[1] ].max, y
        end
      end
      curves.each_cons(2) do |previous, following|
        incoming = previous.last.zip(previous[1]).map { |endpoint, control| endpoint - control }
        outgoing = following.first.zip(previous.last).map { |control, endpoint| control - endpoint }
        assert_in_delta incoming[1] / incoming[0], outgoing[1] / outgoing[0], 0.001
      end
    end
  end

  test "two observations use a straight segment and flat unknown runs stay disconnected" do
    document = render_chart([ nil, 0, 0, nil, nil, 3, 1, nil ])

    assert_equal 2, document.css("path").size
    assert document.css("path").all? { |path| path["d"].include?(" L ") }
    assert_equal 4, document.css("circle").size
  end

  test "unknown data renders no curves or observations" do
    document = render_chart([ nil, nil, nil ])

    assert_empty document.css("path, circle")
  end

  test "plot wide tooltips include exact samples gaps year and keyboard access" do
    document = render_chart([ 0, nil, 4 ])
    points = JSON.parse(document.at_css("[data-controller=activity-chart]")["data-activity-chart-points-value"])

    assert_equal "Sep 29, 2026 12:00 UTC\nAll streams: 0 streams\n1 poll", points.first
    assert_equal "Sep 29, 2026 12:10 UTC\nAll streams: Not observed\n0 polls", points.second
    assert_equal "0", document.at_css("svg")["tabindex"]
    assert_equal "concurrency-tooltip", document.at_css("svg")["aria-describedby"]
    assert_equal "manual", document.at_css("[role=tooltip]")["popover"]
    assert document.at_css("rect[data-activity-chart-target=plot]")
  end

  test "bandwidth tooltips distinguish complete bandwidth polls from total polls" do
    text = activity_chart_tooltip({ at: Time.utc(2026, 10, 3), bandwidth: 12.75, samples: 10, bandwidth_samples: 6 },
      { bandwidth: { label: "Plex bandwidth estimate" } }, "Mbps")

    assert_includes text, "Plex bandwidth estimate: 12.75 Mbps"
    assert_includes text, "6 complete bandwidth polls of 10 polls"
  end

  private

  def render_chart(values)
    chart = Struct.new(:points) do
      def peak(key)
        points.filter_map { |point| point[key] }.max
      end
    end.new(values.each_with_index.map do |value, index|
      { at: Time.utc(2026, 9, 29, 12) + index * 10.minutes, total: value, samples: value.nil? ? 0 : 1 }
    end)
    html = activity_chart_svg(chart, series: { total: { label: "All streams", color: "#67e8f9" } }, unit: "streams", title: "Concurrency")
    Nokogiri::HTML.fragment(html)
  end
end
