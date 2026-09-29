class CreateAdminUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :admin_users do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.integer :session_version, null: false, default: 0
      t.timestamps
    end

    add_index :admin_users, :email, unique: true
  end
end
