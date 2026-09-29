class CreateAdminInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :admin_invitations do |t|
      t.string :email, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.datetime :revoked_at
      t.references :invited_by, foreign_key: { to_table: :admin_users, on_delete: :nullify }
      t.timestamps
    end

    add_index :admin_invitations, :token_digest, unique: true
  end
end
