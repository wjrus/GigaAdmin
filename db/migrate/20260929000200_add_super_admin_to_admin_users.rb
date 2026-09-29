class AddSuperAdminToAdminUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :admin_users, :super_admin, :boolean, null: false, default: false
    execute <<~SQL
      UPDATE admin_users
      SET super_admin = TRUE
      WHERE id = (SELECT id FROM admin_users ORDER BY created_at, id LIMIT 1)
    SQL
  end

  def down
    remove_column :admin_users, :super_admin
  end
end
