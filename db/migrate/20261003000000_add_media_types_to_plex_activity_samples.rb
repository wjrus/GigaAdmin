class AddMediaTypesToPlexActivitySamples < ActiveRecord::Migration[8.1]
  def change
    # Older samples did not record media types; null must remain distinct from idle.
    add_column :plex_activity_samples, :movie_sessions, :integer
    add_column :plex_activity_samples, :episode_sessions, :integer
  end
end
