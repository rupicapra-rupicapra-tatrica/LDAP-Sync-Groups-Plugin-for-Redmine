class LdapSyncGroupsController < ApplicationController
  layout 'admin'
  before_action :require_admin
  
  def index
    @logs = SyncLog.recent
    @ldap_auths = AuthSourceLdap.all
    @selected_auth_id = LdapSetting.get('ldap_auth_id').to_i
    @admin_group_guid = LdapSetting.get('admin_group_guid')
    @admin_group_name = LdapSetting.get('admin_group_name')
    @ad_groups = load_ad_groups
  end

  def save
    if params[:settings]
      params[:settings].except('admin_group_guid').each do |key, value|
        if value.present?
          LdapSetting.set(key, value)
        else
          LdapSetting.set(key, '')
        end
      end
      
      # Tratează checkbox-urile care nu vin în params când sunt debifate
      unless params[:settings].key?('verbose_logging')
        LdapSetting.set('verbose_logging', 'false')
      end
      
      unless params[:settings].key?('send_report_only_on_changes')
        LdapSetting.set('send_report_only_on_changes', 'false')
      end
      
      flash[:notice] = "Settings saved successfully"

      if params[:settings].key?('admin_group_guid')
        save_admin_group(params[:settings]['admin_group_guid'])
      end
    end
    redirect_to action: :index
  end
  
  def sync
    dry_run = params[:dry_run] == '1'
    
    begin
      require_relative '../../lib/ldap_sync_service'
      service = LdapSyncService.new(dry_run)
      result = service.run
      
      flash[:notice] = "Sync completed: #{result[:users_in_redmine]} users in Redmine, #{result[:groups_processed]} groups, #{result[:users_added]} added, #{result[:users_removed]} removed"
      if LdapSetting.get('admin_group_guid').present?
        flash[:notice] += ", admin rights: #{result[:admins_granted]} granted, #{result[:admins_revoked]} revoked"
      end
      flash[:warning] = "DRY RUN - No changes made" if dry_run
    rescue => e
      flash[:error] = "Sync failed: #{e.message}"
      logger.error "LDAP Sync Error: #{e.backtrace.join("\n")}"
    end
    
    redirect_to action: :index
  end
  
  def clear_logs
    SyncLog.delete_all
    flash[:notice] = "Logs cleared"
    redirect_to action: :index
  end

  private

  def directory
    auth = AuthSourceLdap.find_by(id: LdapSetting.get('ldap_auth_id').to_i)
    auth && LdapSyncGroups::Directory.from_auth_source(auth)
  end

  # All groups in the domain, for the admin group dropdown
  def load_ad_groups
    dir = directory
    return [] unless dir

    dir.open { dir.groups(dir.naming_context) }
  rescue LdapSyncGroups::Directory::Error => e
    @ad_groups_error = e.message
    []
  end

  # Stores the group by its GUID, which survives renames and moves in AD
  def save_admin_group(guid)
    if guid.blank?
      LdapSetting.set('admin_group_guid', '')
      LdapSetting.set('admin_group_name', '')
      return
    end
    return if guid == LdapSetting.get('admin_group_guid')

    dir = directory
    group = dir && dir.open { dir.find_group(guid) }
    if group
      LdapSetting.set('admin_group_guid', group.guid)
      LdapSetting.set('admin_group_name', group.name)
    else
      flash[:error] = "Admin group not changed: group not found in AD"
    end
  rescue LdapSyncGroups::Directory::Error => e
    flash[:error] = "Admin group not changed: #{e.message}"
  end
end
