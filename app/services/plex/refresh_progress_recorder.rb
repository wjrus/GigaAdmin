module Plex
  class RefreshProgressRecorder
    def initialize(refresh_run)
      @refresh_run = refresh_run
    end

    def call(event)
      if event[:phase] == "account"
        record_account_progress(event)
      else
        record_page_progress(event)
      end
    end

    private

    attr_reader :refresh_run

    def record_account_progress(event)
      refresh_run.update!(
        account_lookups_completed: event.fetch(:index),
        account_lookups_total: event.fetch(:total),
        history_users_matched: event.fetch(:matches),
        history_users_remaining: event.fetch(:remaining),
        last_message: "Account lookup #{event.fetch(:index)}/#{event.fetch(:total)}: #{event.fetch(:label)}"
      )
      Rails.logger.info(
        "[plex.refresh] run=#{refresh_run.id} phase=account " \
        "lookup=#{event.fetch(:index)}/#{event.fetch(:total)} " \
        "matches=#{event.fetch(:matches)} remaining=#{event.fetch(:remaining)} " \
        "label=#{event.fetch(:label).inspect}"
      )
    end

    def record_page_progress(event)
      stop_reason = event[:stop_reason].presence || "none"
      refresh_run.with_lock do
        refresh_run.update!(
          history_pages_retrieved: event.fetch(:page),
          history_rows_retrieved: refresh_run.history_rows_retrieved + event.fetch(:rows),
          history_users_matched: event.fetch(:matches),
          history_users_remaining: event.fetch(:remaining),
          last_message: page_message(event)
        )
      end
      Rails.logger.info(
        "[plex.refresh] run=#{refresh_run.id} phase=history " \
        "page=#{event.fetch(:page)} page_rows=#{event.fetch(:rows)} " \
        "total_rows=#{refresh_run.history_rows_retrieved} " \
        "matches=#{event.fetch(:matches)} remaining=#{event.fetch(:remaining)} " \
        "stop_reason=#{stop_reason}"
      )
    end

    def page_message(event)
      message = "History page #{event.fetch(:page)} retrieved: " \
        "#{event.fetch(:rows).to_fs(:delimited)} rows, #{event.fetch(:matches)} users matched, " \
        "#{event.fetch(:remaining)} remaining"
      message += " (#{event.fetch(:stop_reason)})" if event[:stop_reason].present?
      message
    end
  end
end
