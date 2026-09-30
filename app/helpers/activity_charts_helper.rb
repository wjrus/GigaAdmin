module ActivityChartsHelper
  def activity_chart_svg(chart, series:, unit:, title:)
    width = 720.0
    height = 180.0
    left = 48.0
    top = 12.0
    plot_width = width - left - 12
    plot_height = height - top - 28
    maximum = [ series.keys.filter_map { |key| chart.peak(key) }.max.to_f, 1 ].max.ceil
    elements = [ content_tag(:title, title) ]
    ticks = unit == "streams" && maximum == 1 ? [ 0, 1 ] : [ 0, 0.5, 1 ]
    ticks.each do |fraction|
      y = top + plot_height * (1 - fraction)
      elements << tag.line(x1: left, x2: width - 12, y1: y, y2: y, stroke: "currentColor", opacity: "0.15")
      tick = maximum * fraction
      precision = unit == "Mbps" || tick != tick.to_i ? 1 : 0
      elements << content_tag(:text, number_with_precision(tick, precision: precision),
        x: left - 7, y: y + 4, "text-anchor": "end", fill: "currentColor", "font-size": 11)
    end
    series.each do |key, options|
      segments = [ [] ]
      chart.points.each_with_index do |point, index|
        if point[key].nil?
          segments << [] unless segments.last.empty?
          next
        end
        x = left + plot_width * index / [ chart.points.size - 1, 1 ].max
        y = top + plot_height * (1 - point[key].to_f / maximum)
        segments.last << "#{x.round(2)},#{y.round(2)}"
        tooltip = "#{point[:at].strftime('%b %-d %H:%M UTC')}: #{options[:label]} #{point[key]} #{unit}; #{point[:samples]} polls"
        elements << content_tag(:circle, content_tag(:title, tooltip), cx: x.round(2), cy: y.round(2), r: 2, fill: options[:color])
      end
      segments.reject(&:empty?).each do |segment|
        elements << tag.polyline(points: segment.join(" "), fill: "none", stroke: options[:color], "stroke-width": 2)
      end
    end
    [ [ chart.points.first, left, "start" ], [ chart.points.last, width - 12, "end" ] ].each do |point, x, anchor|
      elements << content_tag(:text, point[:at].strftime("%b %-d %H:%M UTC"), x: x, y: height - 4,
        "text-anchor": anchor, fill: "currentColor", "font-size": 11)
    end
    content_tag(:svg, safe_join(elements), viewBox: "0 0 #{width.to_i} #{height.to_i}", role: "img",
      "aria-label": title, class: "mt-4 w-full min-w-[32rem] text-zinc-400")
  end
end
