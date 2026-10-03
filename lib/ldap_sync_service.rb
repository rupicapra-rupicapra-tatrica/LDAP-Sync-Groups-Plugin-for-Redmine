class LdapSyncService
  # Seconds the LDAP reads of a login sync may take
  LOGIN_TIMEOUT = 10
  # Marks dry-run log entries, so the log shows what a live sync would do
  DRY_RUN_PREFIX = '🔍 DRY RUN | '

  def initialize(dry_run = false)
    @dry_run = dry_run

    auth_id = LdapSetting.get('ldap_auth_id').to_i
    @auth = AuthSourceLdap.find_by(id: auth_id)

    if @auth.nil?
      raise "No LDAP authentication mode selected. Please configure in plugin settings."
    end

    @directory = LdapSyncGroups::Directory.from_auth_source(@auth)
    @membership = LdapSyncGroups::Membership.new(dry_run: @dry_run)
    @admin_group_guid = LdapSetting.get('admin_group_guid')
    @admin_group_name = LdapSetting.get('admin_group_name')
    @verbose = LdapSetting.get('verbose_logging') == 'true'
    @report_email = LdapSetting.get('report_email')
    @send_report_only_on_changes = LdapSetting.get('send_report_only_on_changes') == 'true'
    
    @stats = {
      groups_processed: 0, 
      users_added: 0,
      users_removed: 0,
      admins_granted: 0,
      admins_revoked: 0
    }
    
    @created_groups = []
    @unchanged_groups = []
    @changes = []
    @all_groups = []
  end
  
  def log(msg, level = 'info')
    puts "[#{Time.now}] #{msg}"
    
    if @verbose
      store_log(msg, level)
    else
      important_patterns = ['===', '---', 'Synced groups', '✅ Groups processed',
                            '📊', '✓ No changes', 'ADD user',
                            'REMOVE user', 'Create group',
                            'Rename group', 'Admin group', 'ADMIN']
      
      if important_patterns.any? { |pattern| msg.include?(pattern) }
        store_log(msg, level)
      end
    end
  end
  
  def log_error(msg)
    puts "[#{Time.now}] ERROR: #{msg}"
    store_log("ERROR: #{msg}", 'error')
    @changes << "ERROR: #{msg}"
  end
  
  def store_log(msg, level)
    SyncLog.create(message: @dry_run ? "#{DRY_RUN_PREFIX}#{msg}" : msg, level: level)
  end
  
  def run
    log("=== LDAP Sync Started (DRY RUN: #{@dry_run}) ===")

    begin
      @directory.open do
        log("--- Syncing groups ---")
        sync_groups

        if @admin_group_guid.present?
          log("--- Syncing admin rights ---")
          sync_admins
        end
      end
    rescue LdapSyncGroups::Directory::Error => e
      log_error(e.message)
      send_report if @report_email.present?
      raise
    end

    # Afișare grupuri procesate
    if @all_groups.any?
      log("✅ Groups processed: #{@all_groups.size} groups (#{@all_groups.join(', ')})")
    else
      log("✅ Groups processed: #{@stats[:groups_processed]}")
    end
    
    log("📊 Groups: #{@stats[:groups_processed]} processed, #{@stats[:users_added]} added, #{@stats[:users_removed]} removed")
    log("📊 Admin rights: #{@stats[:admins_granted]} granted, #{@stats[:admins_revoked]} revoked") if @admin_group_guid.present?
    log("=== Sync Complete ===")
    
    # Trimite raport
    send_report if @report_email.present?
    
    @stats
  end
  
  # All AD groups by GUID, read once per run
  def ad_groups_by_guid
    @ad_groups_by_guid ||= @directory.groups(@directory.naming_context).index_by(&:guid)
  end

  # The groups selected in the plugin settings, each with its AD group (nil when gone from AD)
  def synced_groups
    LdapSyncedGroup.sorted.includes(:group).map { |link| [link, ad_groups_by_guid[link.guid]] }
  end

  def sync_groups
    links = synced_groups
    log("Synced groups: #{links.size} selected")

    links.each do |link, entry|
      # A group missing from AD may be a directory problem, so its Redmine group is left alone
      unless entry
        log_error("AD group #{link.name} (GUID #{link.guid}) not found - group skipped")
        next
      end

      group_name = entry.name
      @stats[:groups_processed] += 1
      @all_groups << group_name

      # Read members first, so a failed lookup never empties or creates a group
      begin
        users = @membership.users_by_login(@directory.member_logins(entry.dn))
      rescue LdapSyncGroups::Directory::Error => e
        log_error("Group #{group_name} skipped: #{e.message}")
        next
      end

      # Recreate the Redmine group if it was deleted; in dry run an unsaved group previews the members
      group = link.group
      group_created = false

      if group.nil?
        group, group_created = @membership.find_or_create_group(group_name)
        unless group.persisted? || @dry_run
          log_error("Cannot create group #{group_name}: #{group.errors.full_messages.join(', ')}")
          next
        end
        if group.persisted? && LdapSyncedGroup.where(group_id: group.id).where.not(id: link.id).exists?
          log_error("Group #{group_name} skipped: its Redmine group is already synced from another AD group")
          next
        end
        link.update!(group: group) unless @dry_run
        if group_created
          @created_groups << group_name
          @changes << "📁 Created group: #{group_name}"
        end
      elsif group.lastname != group_name
        # The AD group was renamed
        old_name = group.lastname
        if @dry_run || group.update(lastname: group_name)
          log("✏️ Rename group: #{old_name} → #{group_name}")
          @changes << "✏️ Renamed group: #{old_name} → #{group_name}"
        else
          log_error("Cannot rename group #{old_name} to #{group_name}: #{group.errors.full_messages.join(', ')}")
          group.restore_attributes
        end
      end
      link.update!(name: group_name) unless @dry_run || link.name == group_name

      added, removed = @membership.apply_group(group, users)
      added_users = added.map(&:login)
      removed_users = removed.map(&:login)
      @stats[:users_added] += added_users.size
      @stats[:users_removed] += removed_users.size
      added_users.each { |u| @changes << "➕ Added user #{u} to group #{group_name}" }
      removed_users.each { |u| @changes << "➖ Removed user #{u} from group #{group_name}" }

      # Log changes
      added_users.each { |u| log("➕ ADD user: #{u} to #{group_name}") }
      removed_users.each { |u| log("➖ REMOVE user: #{u} from #{group_name}") }
      
      if group_created
        log("📁 Create group: #{group_name}")
      elsif added_users.empty? && removed_users.empty?
        @unchanged_groups << group_name
      end
    end
    
    # Log unchanged groups
    if @unchanged_groups.any?
      log("✓ No changes for group: #{@unchanged_groups.join(', ')}")
    end
    
    # Log created groups
    if @created_groups.any?
      log("📁 Create groups: #{@created_groups.join(', ')}")
    end
  end

  # Makes members of the AD admin group Redmine admins and everyone else not.
  # Only users of the selected LDAP authentication mode are touched.
  def sync_admins
    begin
      admin_group = find_admin_group
      return unless admin_group

      admin_logins = @directory.member_logins(admin_group.dn).map(&:downcase)
    rescue LdapSyncGroups::Directory::Error => e
      log_error("Admin rights left unchanged: #{e.message}")
      return
    end

    log("Admin group: #{admin_group.name} (#{admin_logins.size} members)")
    users = User.where(auth_source_id: @auth.id).to_a
    apply_admin_rights(users.to_h { |user| [user, admin_logins.include?(user.login.downcase)] })
  end

  # Syncs one user's group memberships and admin rights, used at login.
  # All LDAP reads finish under a time limit before anything is written.
  def sync_user(user)
    return unless user.auth_source_id == @auth.id

    entry = admin_group = nil
    user_guids = []
    Timeout.timeout(LOGIN_TIMEOUT) do
      @directory.open do
        entry = @directory.find_user(user.login)
        if entry
          user_guids = @directory.groups_of(entry.dn, @directory.naming_context).map(&:guid)
          ad_groups_by_guid
          admin_group = find_admin_group
        end
      end
    end
    return unless entry

    # As in the full sync, groups missing from AD or Redmine are left alone
    links = LdapSyncedGroup.includes(:group).select { |link| link.group && ad_groups_by_guid.key?(link.guid) }
    groups = links.map(&:group)
    user_groups = links.select { |link| user_guids.include?(link.guid) }.map(&:group)
    joined, left = @membership.apply_user(user, groups, user_groups)
    joined.each do |group|
      log("➕ ADD user: #{user.login} to #{group.lastname} (at login)")
      @stats[:users_added] += 1
    end
    left.each do |group|
      log("➖ REMOVE user: #{user.login} from #{group.lastname} (at login)")
      @stats[:users_removed] += 1
    end

    apply_admin_rights({ user => user_guids.include?(admin_group.guid) }, ' (at login)') if admin_group
    @stats
  end

  # The configured AD admin group, or nil when none is set or it is gone from AD
  def find_admin_group
    return if @admin_group_guid.blank?

    group = ad_groups_by_guid[@admin_group_guid]
    log_error("Admin group #{@admin_group_name} not found in AD - admin rights left unchanged") unless group
    group
  end

  # Applies a { user => admin? } map. Revocations are skipped if they would
  # leave Redmine without an active admin.
  def apply_admin_rights(desired, note = '')
    granted = desired.select { |user, admin| admin && !user.admin? }.keys
    revoked = desired.select { |user, admin| !admin && user.admin? }.keys

    remaining = User.active.admin.where.not(id: revoked.map(&:id)).count + granted.count(&:active?)
    if revoked.any? && remaining.zero?
      log_error("Admin rights not revoked from #{revoked.map(&:login).join(', ')}: Redmine would be left without an active admin")
      revoked = []
    end

    # Send Redmine's security notifications before a cron run's process exits
    Mailer.with_synched_deliveries do
      granted.each do |user|
        @membership.apply_admin(user, true)
        log("👑 GRANT ADMIN: #{user.login}#{note}")
        @changes << "👑 Granted admin rights: #{user.login}#{note}"
        @stats[:admins_granted] += 1
      end
      revoked.each do |user|
        @membership.apply_admin(user, false)
        log("🚫 REVOKE ADMIN: #{user.login}#{note}")
        @changes << "🚫 Revoked admin rights: #{user.login}#{note}"
        @stats[:admins_revoked] += 1
      end
    end
  end

  def send_report
    return if @report_email.blank?
    
    # Dacă e configurat să trimită doar la modificări și nu există modificări, nu trimite
    if @send_report_only_on_changes && @changes.empty?
      puts "No changes detected. Report not sent."
      return
    end
    
    subject = "Redmine LDAP Sync Groups - #{Time.now.strftime('%Y-%m-%d %H:%M')}"
    
    if @changes.empty?
      body = "No changes detected during LDAP synchronization.\n\n"
      body += "=== Statistics ===\n"
      body += "Groups processed: #{@stats[:groups_processed]} groups\n"
      if @all_groups.any?
        body += "Groups list: #{@all_groups.join(', ')}\n"
      end
      body += "Dry run: #{@dry_run ? 'Yes (no changes applied)' : 'No'}\n"
    else
      body = "=== LDAP Sync Changes Report ===\n\n"
      body += "Synchronization completed at: #{Time.now}\n"
      body += "Dry run: #{@dry_run ? 'Yes (no changes applied)' : 'No'}\n\n"
      
      body += "=== Statistics ===\n"
      body += "Groups processed: #{@stats[:groups_processed]} groups\n"
      if @all_groups.any?
        body += "Groups list: #{@all_groups.join(', ')}\n"
      end
      body += "Users added to groups: #{@stats[:users_added]}\n"
      body += "Users removed from groups: #{@stats[:users_removed]}\n"
      if @admin_group_guid.present?
        body += "Admin rights granted: #{@stats[:admins_granted]}\n"
        body += "Admin rights revoked: #{@stats[:admins_revoked]}\n"
      end
      body += "\n"
      
      body += "=== Changes ===\n"
      @changes.each do |change|
        body += "• #{change}\n"
      end
    end
    
    body += "\n---\n"
    body += "LDAP Sync Plugin v#{Redmine::Plugin.find(:ldap_sync_groups).version} | Steel..xD"
    
    begin
      ActionMailer::Base.mail(
        from: Setting.mail_from,
        to: @report_email,
        subject: subject,
        body: body
      ).deliver
      puts "✅ Report sent to #{@report_email}"
    rescue => e
      puts "❌ Failed to send report: #{e.message}"
    end
  end
end
