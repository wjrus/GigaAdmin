module ApplicationHelper
  def plex_image_url(path)
    path = path.to_s
    return if path.blank?

    uri = URI(path)
    return if uri.fragment || (uri.absolute? && (!uri.is_a?(URI::HTTP) || uri.host.blank?))
    return if !uri.absolute? && uri.host

    proxy_path = uri.path
    proxy_path = "/#{proxy_path}" unless proxy_path.start_with?("/")
    query = URI.decode_www_form(uri.query.to_s).reject { |key, _| key.casecmp?("X-Plex-Token") }
    proxy_path += "?#{URI.encode_www_form(query)}" if query.any?

    plex_cover_path(path: proxy_path)
  rescue URI::InvalidURIError, ArgumentError, ActionController::UrlGenerationError
    nil
  end

  def plex_timestamp(value)
    return "Never" if value.blank?

    l(Time.zone.at(value.to_i), format: :long)
  end

  def optional_plex_timestamp(value)
    return "Unknown" if value.blank?

    plex_timestamp(value)
  end

  def users_sort_link(label, sort)
    active = @sort == sort
    next_direction = active && @direction == "asc" ? "desc" : "asc"
    indicator = active ? (@direction == "asc" ? "▲" : "▼") : "↕"
    aria_label = if active
      "#{label}, sorted #{@direction == 'asc' ? 'ascending' : 'descending'}. Activate to sort #{next_direction == 'asc' ? 'ascending' : 'descending'}."
    else
      "#{label}, not sorted. Activate to sort #{next_direction == 'asc' ? 'ascending' : 'descending'}."
    end

    link_to users_path(request.query_parameters.merge(sort: sort, direction: next_direction)), class: "inline-flex items-center gap-1 hover:text-white", aria: { label: aria_label } do
      safe_join([
        label,
        tag.span(indicator, aria: { hidden: true }, class: "text-[0.68rem] leading-none text-zinc-500")
      ], " ")
    end
  end

  def percentage_width(value, max_value)
    return 0 if max_value.to_i <= 0

    ((value.to_f / max_value) * 100).round(1)
  end
end
