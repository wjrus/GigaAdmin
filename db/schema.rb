# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_29_000200) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "admin_invitations", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "expires_at", null: false
    t.bigint "invited_by_id"
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["invited_by_id"], name: "index_admin_invitations_on_invited_by_id"
    t.index ["token_digest"], name: "index_admin_invitations_on_token_digest", unique: true
  end

  create_table "admin_users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.integer "session_version", default: 0, null: false
    t.boolean "super_admin", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_admin_users_on_email", unique: true
  end

  create_table "plex_now_playing_samples", force: :cascade do |t|
    t.string "account_id"
    t.datetime "created_at", null: false
    t.integer "duration"
    t.string "full_title"
    t.string "ip_address"
    t.string "library_title"
    t.string "machine_identifier", null: false
    t.string "media_type"
    t.jsonb "metadata", default: {}, null: false
    t.string "player_platform"
    t.string "player_title"
    t.integer "progress_percent"
    t.string "rating_key"
    t.datetime "sampled_at", null: false
    t.string "session_id"
    t.string "state"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "user_label"
    t.integer "view_offset"
    t.index ["machine_identifier", "account_id", "sampled_at"], name: "index_now_playing_samples_on_machine_account_sampled"
    t.index ["machine_identifier", "sampled_at"], name: "idx_on_machine_identifier_sampled_at_ee541fa62c"
  end

  create_table "plex_stream_events", force: :cascade do |t|
    t.string "account_id", null: false
    t.string "cover_path"
    t.datetime "created_at", null: false
    t.integer "duration"
    t.string "full_title"
    t.string "ip_address"
    t.string "library_title"
    t.string "machine_identifier", null: false
    t.string "media_type"
    t.jsonb "metadata", default: {}, null: false
    t.string "player_platform"
    t.string "player_title"
    t.string "rating_key"
    t.string "title"
    t.datetime "updated_at", null: false
    t.integer "view_offset"
    t.datetime "viewed_at", null: false
    t.index ["machine_identifier", "account_id", "viewed_at", "rating_key"], name: "index_stream_events_on_machine_account_viewed_rating", unique: true
    t.index ["machine_identifier", "account_id", "viewed_at"], name: "index_stream_events_on_machine_account_viewed"
    t.index ["machine_identifier", "viewed_at"], name: "index_stream_events_on_machine_viewed"
  end

  create_table "plex_user_notes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.string "last_edited_by"
    t.text "notes"
    t.string "plex_user_id", null: false
    t.boolean "suppressed", default: false, null: false
    t.datetime "suppressed_at"
    t.string "suppressed_by"
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["plex_user_id"], name: "index_plex_user_notes_on_plex_user_id", unique: true
  end

  create_table "refresh_runs", force: :cascade do |t|
    t.integer "account_lookups_completed", default: 0, null: false
    t.integer "account_lookups_total", default: 0, null: false
    t.string "admin_email"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.datetime "finished_at"
    t.integer "history_pages_retrieved", default: 0, null: false
    t.integer "history_rows_retrieved", default: 0, null: false
    t.integer "history_users_matched", default: 0, null: false
    t.integer "history_users_remaining", default: 0, null: false
    t.boolean "include_history", default: false, null: false
    t.string "last_message"
    t.string "machine_identifier", null: false
    t.bigint "share_snapshot_id"
    t.datetime "started_at"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["machine_identifier", "created_at"], name: "index_refresh_runs_on_machine_identifier_and_created_at"
    t.index ["share_snapshot_id"], name: "index_refresh_runs_on_share_snapshot_id"
    t.index ["status"], name: "index_refresh_runs_on_status"
  end

  create_table "share_audit_logs", force: :cascade do |t|
    t.string "action", null: false
    t.string "admin_email", null: false
    t.datetime "created_at", null: false
    t.jsonb "libraries_added", default: [], null: false
    t.jsonb "libraries_after", default: [], null: false
    t.jsonb "libraries_removed", default: [], null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "plex_user_id"
    t.string "share_id"
    t.string "target_email"
    t.string "target_label"
    t.datetime "updated_at", null: false
    t.index ["admin_email"], name: "index_share_audit_logs_on_admin_email"
    t.index ["created_at"], name: "index_share_audit_logs_on_created_at"
    t.index ["plex_user_id"], name: "index_share_audit_logs_on_plex_user_id"
    t.index ["share_id"], name: "index_share_audit_logs_on_share_id"
  end

  create_table "share_snapshots", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "fetched_at", null: false
    t.jsonb "libraries", default: [], null: false
    t.string "machine_identifier", null: false
    t.jsonb "server", default: {}, null: false
    t.datetime "updated_at", null: false
    t.jsonb "users", default: [], null: false
    t.index ["machine_identifier", "fetched_at"], name: "index_share_snapshots_on_machine_identifier_and_fetched_at"
  end

  add_foreign_key "admin_invitations", "admin_users", column: "invited_by_id", on_delete: :nullify
end
