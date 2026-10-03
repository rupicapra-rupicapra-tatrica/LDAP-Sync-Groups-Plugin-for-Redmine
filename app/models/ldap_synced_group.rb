# An AD group selected for syncing, linked by objectGUID to its Redmine group.
# name is the AD group's name as of the last sync.
class LdapSyncedGroup < ActiveRecord::Base
  self.table_name = 'ldap_synced_groups'

  belongs_to :group, optional: true

  validates :guid, presence: true, uniqueness: true

  scope :sorted, -> { order(:name) }
end
