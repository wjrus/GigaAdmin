class CreatePlexActivitySamples < ActiveRecord::Migration[8.1]
  def change
    create_table :plex_activity_samples do |t|
      t.string :machine_identifier, null: false
      t.datetime :sampled_at, null: false
      %i[total_sessions playing_sessions paused_sessions transcode_sessions direct_play_sessions direct_stream_sessions unknown_sessions bandwidth_sessions].each do |column|
        t.integer column, null: false, default: 0
      end
      t.bigint :bandwidth_kbps, null: false, default: 0
      t.timestamps
    end
    add_index :plex_activity_samples, [ :machine_identifier, :sampled_at ], unique: true
    add_index :plex_activity_samples, :sampled_at
  end
end
