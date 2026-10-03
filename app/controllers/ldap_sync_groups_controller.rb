class LdapSyncGroupsController < ApplicationController
  layout 'admin'
  before_action :require_admin
  # sync.json and sync_user.json accept an admin's API key
  accept_api_auth :sync, :sync_user
  
  def index
    @logs = SyncLog.recent
    @ldap_auths = AuthSourceLdap.all
    @selected_auth_id = LdapSetting.get('ldap_auth_id').to_i
    @admin_group_guid = LdapSetting.get('admin_group_guid')
    @admin_group_name = LdapSetting.get('admin_group_name')
    @synced_groups = LdapSyncedGroup.sorted.includes(:group).to_a
    load_ad_groups
  end

  # Selects an AD group for syncing and creates its Redmine group right away
  def add_group
    guid = params[:guid].to_s
    if guid.blank?
      flash[:error] = "Select a group to add"
    elsif LdapSyncedGroup.exists?(guid: guid)
      flash[:error] = "This group is already synced"
    else
      dir = directory
      entry = dir && dir.open { dir.find_group(guid) }
      if entry.nil?
        flash[:error] = "Group not added: not found in AD"
      else
        group, created = LdapSyncGroups::Membership.new.find_or_create_group(entry.name)
        if !group.persisted?
          flash[:error] = "Group not added: #{group.errors.full_messages.join(', ')}"
        elsif LdapSyncedGroup.exists?(group_id: group.id)
          flash[:error] = "Group not added: the Redmine group #{group.lastname} is already synced from another AD group"
        else
          LdapSyncedGroup.create!(guid: entry.guid, name: entry.name, group: group)
          if created
            SyncLog.create(message: "📁 Create group: #{entry.name} (added to synced groups)", level: 'info')
            flash[:notice] = "Added #{entry.name}. Its members are synced at the next sync."
          else
            flash[:warning] = "Added #{entry.name}, linked to the existing Redmine group of the same name. " \
                              "At the next sync its members are replaced by the AD members, and removing it here deletes it."
          end
        end
      end
    end
    redirect_to action: :index
  rescue LdapSyncGroups::Directory::Error => e
    flash[:error] = "Group not added: #{e.message}"
    redirect_to action: :index
  end

  # Stops syncing a group and deletes its Redmine group
  def remove_group
    link = LdapSyncedGroup.find_by(id: params[:id])
    if link
      name = link.group&.lastname || link.name
      LdapSyncedGroup.transaction do
        link.group&.destroy
        link.destroy
      end
      SyncLog.create(message: "🗑 Delete group: #{name} (removed from synced groups)", level: 'info')
      flash[:notice] = "Removed #{name} and deleted its Redmine group"
    end
    redirect_to action: :index
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
    dry_run = dry_run?
    
    begin
      require_relative '../../lib/ldap_sync_service'
      service = LdapSyncService.new(dry_run)
      result = service.run
    rescue => e
      logger.error "LDAP Sync Error: #{e.backtrace.join("\n")}"
      return respond_to do |format|
        format.html do
          flash[:error] = "Sync failed: #{e.message}"
          redirect_to action: :index
        end
        format.json { render_sync_error(e) }
      end
    end
    
    respond_to do |format|
      format.html do
        flash[:notice] = "Sync completed: #{result[:groups_processed]} groups, #{result[:users_added]} added, #{result[:users_removed]} removed"
        if LdapSetting.get('admin_group_guid').present?
          flash[:notice] += ", admin rights: #{result[:admins_granted]} granted, #{result[:admins_revoked]} revoked"
        end
        flash[:warning] = "DRY RUN - No changes made. The log below shows what a live sync would change." if dry_run
        redirect_to action: :index
      end
      format.json { render json: result.merge(dry_run: dry_run, errors: service.errors) }
    end
  end
  
  # API only: syncs one user's group memberships and admin rights from AD
  def sync_user
    return head(:not_acceptable) unless api_request?
    
    user = User.find_by_login(params[:login].to_s)
    unless user
      return render json: { errors: ["No Redmine user with login '#{params[:login]}'"] }, status: :not_found
    end
    unless user.auth_source_id.present? && user.auth_source_id == LdapSetting.get('ldap_auth_id').to_i
      return render json: { errors: ["User #{user.login} doesn't log in through the selected LDAP authentication mode, so the plugin doesn't manage them"] },
                    status: :unprocessable_entity
    end
    
    dry_run = dry_run?
    result = LdapSyncService.new(dry_run).sync_user(user, 'API')
    render json: result.merge(dry_run: dry_run)
  rescue => e
    logger.error "LDAP Sync Error: #{e.backtrace.join("\n")}"
    render_sync_error(e)
  end
  
  def clear_logs
    SyncLog.delete_all
    flash[:notice] = "Logs cleared"
    redirect_to action: :index
  end

  private
  
  def dry_run?
    %w[1 true].include?(params[:dry_run].to_s)
  end
  
  # Configuration problems need fixing; directory problems are worth retrying
  def render_sync_error(error)
    status =
      case error
      when LdapSyncService::ConfigurationError then :unprocessable_entity
      when LdapSyncGroups::Directory::Error, Timeout::Error then :service_unavailable
      else :internal_server_error
      end
    render json: { errors: [error.message] }, status: status
  end

  def directory
    auth = AuthSourceLdap.find_by(id: LdapSetting.get('ldap_auth_id').to_i)
    auth && LdapSyncGroups::Directory.from_auth_source(auth)
  end

  # All groups in the domain for the admin group dropdown, and the groups
  # below the optional Groups DN for the "+ Add" dropdown
  def load_ad_groups
    @ad_groups = @addable_groups = []
    dir = directory
    return unless dir

    dir.open do
      @ad_groups = dir.groups(dir.naming_context)
      groups_dn = LdapSetting.get('ldap_groups_dn')
      @addable_groups = groups_dn.present? ? dir.groups(groups_dn) : @ad_groups
    end
  rescue LdapSyncGroups::Directory::Error => e
    @ad_groups_error = e.message
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
