module LdapSyncGroups
  # Applies directory state to Redmine users and groups. In dry-run mode
  # nothing is written; the return values still describe what would change.
  class Membership
    def initialize(dry_run: false)
      @dry_run = dry_run
    end

    # Redmine users matching the given logins, case-insensitively.
    def users_by_login(logins)
      return [] if logins.empty?

      User.where('LOWER(login) IN (?)', logins.map(&:downcase)).to_a
    end

    # Locks or unlocks the user to match the AD account.
    # Returns :locked, :unlocked or nil when nothing changes.
    def apply_account_status(user, disabled)
      if disabled && user.active?
        user.lock! unless @dry_run
        :locked
      elsif !disabled && user.locked?
        user.activate! unless @dry_run
        :unlocked
      end
    end

    # Sets the user's admin flag. Redmine notifies all admins about the change.
    # Returns :granted, :revoked or nil when nothing changes.
    def apply_admin(user, admin)
      return if user.admin? == admin

      user.update_attribute(:admin, admin) unless @dry_run
      admin ? :granted : :revoked
    end

    # Makes the group's members exactly the given users.
    # Returns [added, removed] users.
    def apply_group(group, users)
      current = group.users.to_a
      added = users - current
      removed = current - users
      unless @dry_run
        added.each { |user| group.users << user }
        removed.each { |user| group.users.delete(user) }
      end
      [added, removed]
    end

    # Makes the user a member of exactly member_of out of the managed groups.
    # Groups outside managed are not touched. Returns [joined, left] groups.
    def apply_user(user, managed, member_of)
      current = user.groups.to_a & managed
      joined = (member_of & managed) - current
      left = current - member_of
      unless @dry_run
        joined.each { |group| group.users << user }
        left.each { |group| group.users.delete(user) }
      end
      [joined, left]
    end
  end
end
