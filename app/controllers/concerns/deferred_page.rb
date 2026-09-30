module DeferredPage
  extend ActiveSupport::Concern

  FRAME_ID = "page-content".freeze

  class_methods do
    def defer_page(action, title:)
      before_action(only: action) do
        next unless request.get? && request.format.html? && params[:partial].blank?

        @deferred_page_title = title
        @deferred_page_request = true
        response.headers["Vary"] = [ response.headers["Vary"], "Turbo-Frame" ].compact.join(", ")
        # Existing inner frames (such as stream-history filters) still need the
        # requested content rather than another outer page shell.
        next if turbo_frame_request? || params[:sync] == "1"

        # Authentication runs first. Expensive page queries run only in the
        # subsequent frame request, leaving navigation immediately available.
        render "shared/deferred_page"
      end
    end
  end

  private

  def deferred_frame_request?
    request.headers["Turbo-Frame"] == FRAME_ID
  end

  def application_layout
    @deferred_page_request && deferred_frame_request? ? "deferred_content" : "application"
  end
end
