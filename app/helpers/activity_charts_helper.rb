module ActivityChartsHelper
  def activity_chart_svg(chart, series:, unit:, title:)
    width = 720.0
    height = 180.0
    left = 48.0
    top = 12.0
    plot_width = width - left - 12
    plot_height = height - top - 28
    maximum = [ series.keys.filter_map { |key| chart.peak(key) }.max.to_f, 1 ].max.ceil
    elements = [ content_tag(:title, title), tag.rect(x: left, y: top, width: plot_width, height: plot_height,
      fill: "transparent", data: { activity_chart_target: "plot" }) ]
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
        segments.last << [ x, y ]
        isolated = (index.zero? || chart.points[index - 1][key].nil?) && chart.points[index + 1]&.dig(key).nil?
        tooltip = "#{point[:at].strftime('%b %-d %H:%M UTC')}: #{options[:label]} #{point[key]} #{unit}; #{point[:samples]} polls"
        elements << content_tag(:circle, content_tag(:title, tooltip), cx: x.round(2), cy: y.round(2), r: 2,
          fill: options[:color], opacity: isolated ? 1 : 0)
      end
      segments.reject(&:empty?).each do |segment|
        elements << tag.path(d: activity_chart_path(segment), fill: "none", stroke: options[:color],
          "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round")
      end
    end
    [ [ chart.points.first, left, "start" ], [ chart.points.last, width - 12, "end" ] ].each do |point, x, anchor|
      elements << content_tag(:text, point[:at].strftime("%b %-d %H:%M UTC"), x: x, y: height - 4,
        "text-anchor": anchor, fill: "currentColor", "font-size": 11)
    end
    elements << tag.line(x1: left, x2: left, y1: top, y2: top + plot_height,
      stroke: "currentColor", "stroke-dasharray": "3 3", "pointer-events": "none", visibility: "hidden",
      data: { activity_chart_target: "cursor" })
    tooltip_id = "#{title.parameterize}-tooltip"
    svg = content_tag(:svg, safe_join(elements), viewBox: "0 0 #{width.to_i} #{height.to_i}", role: "img", tabindex: 0,
      "aria-label": title, "aria-describedby": tooltip_id, "aria-keyshortcuts": "ArrowLeft ArrowRight Home End Escape",
      class: "mt-4 w-full min-w-[32rem] text-zinc-400", data: { activity_chart_target: "svg",
      action: "pointermove->activity-chart#show pointerdown->activity-chart#show focus->activity-chart#focus blur->activity-chart#blur keydown->activity-chart#navigate" })
    tooltip = content_tag(:div, nil, id: tooltip_id, role: "tooltip", hidden: true, popover: "manual",
      class: "activity-chart-tooltip", aria: { live: "polite", atomic: true }, data: { activity_chart_target: "tooltip" })
    content_tag(:div, safe_join([ svg, tooltip ]), class: "activity-chart", data: { controller: "activity-chart",
      activity_chart_points_value: chart.points.map { |point| activity_chart_tooltip(point, series, unit) }.to_json,
      action: "pointerenter->activity-chart#cancelHide pointerleave->activity-chart#leave pointerdown@window->activity-chart#dismissOutside scroll@window->activity-chart#hide:capture resize@window->activity-chart#hide keydown.esc@window->activity-chart#hide" })
  end

  private

  def activity_chart_tooltip(point, series, unit)
    values = series.map do |key, options|
      value = if point[key].nil?
        "Not observed"
      elsif unit == "streams"
        pluralize(point[key], "stream")
      else
        "#{point[key]} #{unit}"
      end
      "#{options[:label]}: #{value}"
    end
    polls = point[:bandwidth_samples].to_i if unit == "Mbps"
    values << "#{pluralize(polls, 'complete bandwidth poll')} of #{point[:samples]} polls" if polls
    [ point[:at].strftime("%b %-d, %Y %H:%M UTC"), *values, pluralize(point[:samples], "poll") ].join("\n")
  end

  def activity_chart_path(points)
    coordinate = ->(point) { point.map { |value| value.round(2) }.join(",") }
    path = [ "M #{coordinate.call(points.first)}" ]
    return path.join if points.one?
    return "#{path.first} L #{coordinate.call(points.last)}" if points.size == 2

    slopes = points.each_cons(2).map { |(x1, y1), (x2, y2)| (y2 - y1) / (x2 - x1) }
    # Monotone tangents round the corners without inventing peaks or dipping below zero.
    tangents = [ slopes.first ] + slopes.each_cons(2).map do |before, after|
      before * after <= 0 ? 0.0 : 2 * before * after / (before + after)
    end + [ slopes.last ]

    points.each_cons(2).with_index do |((x1, y1), (x2, y2)), index|
      step = (x2 - x1) / 3
      control1 = [ x1 + step, y1 + step * tangents[index] ]
      control2 = [ x2 - step, y2 - step * tangents[index + 1] ]
      path << "C #{coordinate.call(control1)} #{coordinate.call(control2)} #{coordinate.call([ x2, y2 ])}"
    end
    path.join(" ")
  end
end
