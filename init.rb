Redmine::Plugin.register :ldap_sync_groups do
  name 'LDAP Sync Groups Plugin'
  author 'Steel..xD'
  description 'Synchronize users and groups from LDAP/Active Directory'
  version '3.0.0'
  
  menu :admin_menu, :ldap_sync_groups,
       { controller: 'ldap_sync_groups', action: 'index' },
       caption: 'LDAP Sync Groups',
       html: { class: 'icon icon-group' }
end

# Loading the listener registers the login hook
LdapSyncGroups::Hooks
