require "json"
require "rexml/document"

class SharesController < ApplicationController
  around_action :serialize_share_changes, only: %i[create update destroy destroy_invite bulk_update refresh]

  def index
    @machine_identifier = required_machine_identifier
    @snapshot = ShareSnapshot.latest_for(@machine_identifier)
    @report = @snapshot&.to_report
    @notes_by_user_id = PlexUserNote.for_users(@report&.users || [])
    @visible_users = (@report&.users || []).reject { |user| @notes_by_user_id[user.id.to_s]&.suppressed? }
  rescue Plex::ConfigurationError => error
    @configuration_error = error.message
  rescue Plex::Client::Error, ActiveRecord::ActiveRecordError => error
    @plex_error = error.message
  end

  def refresh
    active_run = RefreshRun.active_for(required_machine_identifier)
    if active_run
      redirect_to maintenance_path, notice: "Plex refresh is already #{active_run.status}."
      return
    end

    refresh_run = RefreshRun.create!(
      machine_identifier: required_machine_identifier,
      status: "queued",
      admin_email: current_admin_email,
      include_history: truthy_param?(params[:include_history])
    )
    PlexRefreshJob.perform_later(refresh_run.id)

    redirect_to maintenance_path, notice: "Plex refresh queued."
  rescue Plex::ConfigurationError, Plex::Client::Error, ActiveRecord::ActiveRecordError => error
    redirect_to maintenance_path, alert: error.message
  end

  def create
    invited_email = params[:invited_email].to_s.strip
    library_ids = requested_library_ids
    raise Plex::ConfigurationError, "Enter a Plex username or email." if invited_email.blank?
    raise Plex::ConfigurationError, "Choose at least one library to share." if library_ids.empty?

    snapshot = ShareSnapshot.latest_for(required_machine_identifier)
    selected_libraries = libraries_for_ids(snapshot, library_ids)
    client = Plex::Client.from_env
    invite_response = client.create_shared_server(
      required_machine_identifier,
      invited_email,
      library_ids,
      allow_sync: truthy_param?(params[:allow_sync])
    )
    ShareAuditLog.record!(
      action: "library_access_granted",
      admin_email: current_admin_email,
      target: { label: invited_email, email: invited_email },
      libraries_added: selected_libraries,
      libraries_after: selected_libraries,
      metadata: { allow_sync: truthy_param?(params[:allow_sync]) }
    )

    begin
      refresh_snapshot(include_history: false)
    rescue Plex::ConfigurationError, Plex::Client::Error, ActiveRecord::ActiveRecordError
      flash[:alert] = "Invite sent, but the Plex refresh failed. Retry from Maintenance."
    end
    pending_user = ensure_cached_pending_invite(invited_email, selected_libraries, invite_response, allow_sync: truthy_param?(params[:allow_sync]))

    redirect_to pending_user ? user_path(pending_user["id"]) : root_path, notice: "Plex invite sent."
  rescue Plex::ConfigurationError, Plex::Client::Error, ActiveRecord::ActiveRecordError => error
    redirect_to root_path, alert: error.message
  end

  def update
    library_ids = requested_library_ids
    snapshot = ShareSnapshot.latest_for(required_machine_identifier)
    current_user = snapshot_user_for_share(snapshot, params[:share_id])
    previous_libraries = current_user_libraries(current_user)
    expected_version = ShareSnapshot.library_version(previous_libraries.map { |library| library["id"] })
    unless current_user && params[:library_version] == expected_version
      raise Plex::ConfigurationError, "Library access has changed. Reload this user before saving."
    end
    selected_libraries = libraries_for_ids(snapshot, library_ids)
    client = Plex::Client.from_env

    if library_ids.any?
      client.update_shared_server(required_machine_identifier, params[:share_id], library_ids)
    else
      client.remove_shared_server(required_machine_identifier, params[:share_id])
    end

    record_share_update(params[:share_id], current_user, previous_libraries, selected_libraries)
    update_cached_share(params[:share_id], library_ids)
    redirect_to share_redirect_path, notice: "Plex share updated."
  rescue Plex::ConfigurationError, Plex::Client::Error, ActiveRecord::ActiveRecordError => error
    redirect_to share_redirect_path, alert: error.message
  end

  def bulk_update
    user_ids = Array(params[:user_ids]).compact_blank
    library_id = params[:library_id].to_s
    operation = params[:operation].to_s
    raise Plex::ConfigurationError, "Select at least one user." if user_ids.empty?
    raise Plex::ConfigurationError, "Choose a library." if library_id.blank?
    raise Plex::ConfigurationError, "Choose add or remove." unless operation.in?(%w[add remove])

    snapshot = ShareSnapshot.latest_for(required_machine_identifier)
    library = libraries_for_ids(snapshot, [ library_id ]).first
    raise Plex::ConfigurationError, "Library not found in the latest snapshot." unless library

    changed_count = apply_bulk_library_update(snapshot, user_ids, library, operation)
    redirect_to users_path, notice: "Updated #{helpers.pluralize(changed_count, "share")}."
  rescue Plex::ConfigurationError, Plex::Client::Error, ActiveRecord::ActiveRecordError => error
    redirect_to users_path, alert: error.message
  end

  def destroy
    snapshot = ShareSnapshot.latest_for(required_machine_identifier)
    current_user = snapshot_user_for_share(snapshot, params[:share_id])
    raise Plex::ConfigurationError, "Share not found in the latest snapshot. Reload before removing access." unless current_user

    previous_libraries = current_user_libraries(current_user)
    client = Plex::Client.from_env
    client.remove_shared_server(required_machine_identifier, params[:share_id])
    ShareAuditLog.record!(
      action: "library_access_removed",
      admin_email: current_admin_email,
      target: audit_target(current_user),
      share_id: params[:share_id],
      libraries_removed: previous_libraries
    )
    update_cached_share(params[:share_id], [])

    redirect_to root_path, notice: "Plex share removed."
  rescue Plex::ConfigurationError, Plex::Client::Error, ActiveRecord::ActiveRecordError => error
    redirect_to root_path, alert: error.message
  end

  def destroy_invite
    snapshot = ShareSnapshot.latest_for(required_machine_identifier)
    pending_user = snapshot_user_for_id(snapshot, params[:invite_id])
    raise Plex::ConfigurationError, "Pending invite not found in the latest snapshot." unless pending_user&.fetch("pending", false)

    client = Plex::Client.from_env
    begin
      client.cancel_requested_invite(
        params[:invite_id],
        friend: pending_user["invite_friend"],
        home: pending_user["home"],
        server: pending_user.fetch("invite_server", true)
      )
    rescue Plex::Client::Error => error
      raise unless plex_not_found?(error)

      update_cached_invite(params[:invite_id])
      redirect_to root_path, notice: "Pending Plex invite was already gone; local cache cleaned up."
      return
    end
    raise Plex::Client::Error, "Plex still reports this pending invite after cancellation." if pending_invite_still_reported?(client, pending_user)

    ShareAuditLog.record!(
      action: "pending_invite_canceled",
      admin_email: current_admin_email,
      target: audit_target(pending_user),
      libraries_removed: current_user_libraries(pending_user)
    )
    update_cached_invite(params[:invite_id])

    redirect_to root_path, notice: "Pending Plex invite canceled."
  rescue Plex::ConfigurationError, Plex::Client::Error, ActiveRecord::ActiveRecordError => error
    redirect_to root_path, alert: error.message
  end

  private

  def serialize_share_changes(&action)
    ShareSnapshot.with_server_lock(required_machine_identifier, &action)
  rescue Plex::ConfigurationError => error
    redirect_to root_path, alert: error.message
  end

  def refresh_snapshot(include_history: true)
    Plex::SnapshotRefresh.new(
      client: Plex::Client.from_env,
      machine_identifier: required_machine_identifier,
      include_history: include_history
    ).call
  end

  def required_machine_identifier
    ENV["PLEX_MACHINE_IDENTIFIER"].presence ||
      raise(Plex::ConfigurationError, "Missing PLEX_MACHINE_IDENTIFIER in .env")
  end

  def update_cached_share(share_id, library_ids)
    snapshot = ShareSnapshot.latest_for(required_machine_identifier)
    return refresh_snapshot(include_history: false) unless snapshot

    libraries_by_id = snapshot.libraries.index_by { |library| library["id"].to_s }
    selected_libraries = library_ids.filter_map { |library_id| libraries_by_id[library_id.to_s] }
    users = snapshot.users.filter_map do |user|
      next user unless user["share_id"].to_s == share_id.to_s
      next if selected_libraries.empty?

      user.merge(
        "libraries" => selected_libraries,
        "library_count" => selected_libraries.size,
        "all_libraries" => selected_libraries.size == snapshot.libraries.size
      )
    end

    ShareSnapshot.create!(
      machine_identifier: snapshot.machine_identifier,
      server: snapshot.server,
      libraries: snapshot.libraries,
      users: users,
      fetched_at: Time.current
    )
  end

  def update_cached_invite(invite_id)
    snapshot = ShareSnapshot.latest_for(required_machine_identifier)
    return refresh_snapshot(include_history: false) unless snapshot

    ShareSnapshot.create!(
      machine_identifier: snapshot.machine_identifier,
      server: snapshot.server,
      libraries: snapshot.libraries,
      users: snapshot.users.reject { |user| user["id"].to_s == invite_id.to_s && user["pending"] },
      fetched_at: Time.current
    )
  end

  def pending_invite_still_reported?(client, pending_user)
    identifiers = [
      pending_user["id"],
      pending_user["email"],
      pending_user["username"],
      pending_user["title"]
    ].compact_blank.map { |value| value.to_s.downcase }.to_set

    client.requested_invites.any? do |invite|
      [
        invite[:id],
        invite[:email],
        invite[:username],
        invite[:friendly_name],
        invite[:title]
      ].compact_blank.any? { |value| identifiers.include?(value.to_s.downcase) }
    end
  rescue Plex::Client::Error => error
    Rails.logger.warn("[plex.invites] cancellation verification failed: #{error.message}")
    true
  end

  def plex_not_found?(error)
    error.message.match?(/Plex API returned 404\b/)
  end

  def ensure_cached_pending_invite(invited_email, selected_libraries, invite_response, allow_sync:)
    snapshot = ShareSnapshot.latest_for(required_machine_identifier)
    pending_user = pending_user_for_invite(snapshot, invited_email)
    return pending_user if pending_user

    invite_id = invite_id_from_response(invite_response)
    return unless snapshot && invite_id.present?

    pending_user = {
      "id" => invite_id,
      "share_id" => nil,
      "title" => invited_email,
      "username" => invited_email,
      "email" => invited_email,
      "thumb" => nil,
      "home" => false,
      "restricted" => false,
      "allow_sync" => allow_sync,
      "allow_channels" => false,
      "last_seen_at" => nil,
      "last_streamed_at" => nil,
      "last_streamed_title" => nil,
      "last_streamed_type" => nil,
      "invited_at" => Time.current.to_i.to_s,
      "invite_friend" => false,
      "invite_server" => true,
      "pending" => true,
      "all_libraries" => same_library_ids?(snapshot.libraries, selected_libraries),
      "library_count" => selected_libraries.size,
      "libraries" => selected_libraries
    }

    ShareSnapshot.create!(
      machine_identifier: snapshot.machine_identifier,
      server: snapshot.server,
      libraries: snapshot.libraries,
      users: snapshot.users.reject { |user| user["id"].to_s == invite_id.to_s } + [ pending_user ],
      fetched_at: Time.current
    )
    pending_user
  end

  def pending_user_for_invite(snapshot, invited_email)
    invited_email = invited_email.to_s.downcase
    snapshot&.users&.find do |user|
      user["pending"] &&
        [ user["email"], user["username"], user["title"] ].compact.any? { |value| value.to_s.downcase == invited_email }
    end
  end

  def invite_id_from_response(response)
    body = response.to_s.strip
    return if body.blank?

    if body.start_with?("{", "[")
      invite_id_from_json(JSON.parse(body))
    else
      invite_id_from_xml(REXML::Document.new(body))
    end
  rescue JSON::ParserError, REXML::ParseException
    nil
  end

  def invite_id_from_json(payload)
    case payload
    when Hash
      %w[Invite invite SharedServer shared_server sharedServer].each do |key|
        invite_id = invite_id_from_json(payload[key])
        return invite_id if invite_id.present?
      end

      direct_id = payload["id"] || payload["ID"]
      return direct_id if direct_id.present?

      payload.each_value do |value|
        invite_id = invite_id_from_json(value)
        return invite_id if invite_id.present?
      end
    when Array
      payload.each do |value|
        invite_id = invite_id_from_json(value)
        return invite_id if invite_id.present?
      end
    end
  end

  def invite_id_from_xml(document)
    REXML::XPath.first(document, "//Invite|//SharedServer")&.attributes&.[]("id")
  end

  def truthy_param?(value)
    value == true || value.to_s == "1" || value.to_s.casecmp("true").zero?
  end

  def apply_bulk_library_update(snapshot, user_ids, library, operation)
    client = Plex::Client.from_env
    changed_count = 0

    snapshot.users.select { |user| user_ids.include?(user["id"].to_s) }.each do |user|
      next if user["pending"] || user["share_id"].blank?

      previous_libraries = current_user_libraries(user)
      selected_libraries = bulk_selected_libraries(previous_libraries, library, operation)
      next if same_library_ids?(previous_libraries, selected_libraries)

      if selected_libraries.any?
        client.update_shared_server(required_machine_identifier, user["share_id"], selected_libraries.map { |selected| selected["id"].to_s })
      else
        client.remove_shared_server(required_machine_identifier, user["share_id"])
      end
      record_share_update(user["share_id"], user, previous_libraries, selected_libraries)
      update_cached_share(user["share_id"], selected_libraries.map { |selected| selected["id"].to_s })
      changed_count += 1
    end

    changed_count
  end

  def bulk_selected_libraries(previous_libraries, library, operation)
    if operation == "add"
      (previous_libraries + [ library ]).uniq { |selected| selected["id"].to_s }
    else
      previous_libraries.reject { |selected| selected["id"].to_s == library["id"].to_s }
    end
  end

  def same_library_ids?(previous_libraries, selected_libraries)
    previous_libraries.map { |library| library["id"].to_s }.sort == selected_libraries.map { |library| library["id"].to_s }.sort
  end

  def snapshot_user_for_share(snapshot, share_id)
    snapshot&.users&.find { |user| user["share_id"].to_s == share_id.to_s }
  end

  def snapshot_user_for_id(snapshot, user_id)
    snapshot&.users&.find { |user| user["id"].to_s == user_id.to_s }
  end

  def current_user_libraries(user)
    Array(user && user["libraries"])
  end

  def libraries_for_ids(snapshot, library_ids)
    libraries_by_id = snapshot&.libraries.to_a.index_by { |library| library["id"].to_s }
    library_ids.map do |library_id|
      libraries_by_id.fetch(library_id.to_s) do
        raise Plex::ConfigurationError, "A selected library is no longer in the latest snapshot. Reload before saving."
      end
    end
  end

  def requested_library_ids
    ids = params[:library_ids] || []
    unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(String) }
      raise Plex::ConfigurationError, "Invalid library selection. Reload before saving."
    end

    ids.compact_blank.uniq
  end

  def share_redirect_path
    url_from(params[:return_to]) || root_path
  end

  def record_share_update(share_id, user, previous_libraries, selected_libraries)
    if selected_libraries.empty?
      ShareAuditLog.record!(
        action: "library_access_removed",
        admin_email: current_admin_email,
        target: audit_target(user),
        share_id: share_id,
        libraries_removed: previous_libraries
      )
      return
    end

    previous_ids = previous_libraries.map { |library| library["id"].to_s }
    selected_ids = selected_libraries.map { |library| library["id"].to_s }
    added = selected_libraries.select { |library| previous_ids.exclude?(library["id"].to_s) }
    removed = previous_libraries.select { |library| selected_ids.exclude?(library["id"].to_s) }
    return if added.empty? && removed.empty?

    action = if added.any? && removed.any?
      "libraries_changed"
    elsif added.any?
      "libraries_added"
    else
      "libraries_removed"
    end

    ShareAuditLog.record!(
      action: action,
      admin_email: current_admin_email,
      target: audit_target(user),
      share_id: share_id,
      libraries_added: added,
      libraries_removed: removed,
      libraries_after: selected_libraries
    )
  end

  def audit_target(user)
    return { label: "Unknown user" } unless user

    {
      id: user["id"],
      share_id: user["share_id"],
      label: user["username"].presence || user["title"].presence || user["email"],
      email: user["email"]
    }
  end
end
