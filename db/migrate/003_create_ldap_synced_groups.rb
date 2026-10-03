class CreateLdapSyncedGroups < ActiveRecord::Migration[6.1]
  def change
    create_table :ldap_synced_groups do |t|
      t.string :guid, null: false
      t.string :name
      t.integer :group_id
      t.timestamps
    end
    add_index :ldap_synced_groups, :guid, unique: true
  end
end
