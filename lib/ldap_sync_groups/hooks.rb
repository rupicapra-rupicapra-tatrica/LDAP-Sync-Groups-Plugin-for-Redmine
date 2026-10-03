module LdapSyncGroups
  class Hooks < Redmine::Hook::Listener
    # Syncs the user's groups and admin rights right after a successful
    # login. Failures are logged and never block the login.
    def controller_account_success_authentication_after(context = {})
      user = context[:user]
      return unless user&.auth_source_id.present?
      return unless user.auth_source_id == LdapSetting.get('ldap_auth_id').to_i

      LdapSyncService.new(false).sync_user(user)
    rescue => e
      Rails.logger.error "LDAP login sync failed for #{user&.login}: #{e.message}"
      SyncLog.create(message: "ERROR: Login sync for #{user&.login} failed: #{e.message}", level: 'error')
    end
  end
end
