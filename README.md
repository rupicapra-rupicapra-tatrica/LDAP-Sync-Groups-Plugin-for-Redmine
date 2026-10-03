# LDAP Sync Groups Plugin for Redmine

Keeps Redmine in line with Active Directory: mirrors the AD groups you choose into Redmine groups, and makes members of one AD group Redmine administrators. It syncs everything on demand or from cron, and syncs each user's groups and admin rights again when they log in.

**Version:** 3.0.0 · **Author:** jk · **License:** GPL-3.0

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [What a sync does](#what-a-sync-does)
- [Running a sync](#running-a-sync)
- [Logs and reports](#logs-and-reports)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Upgrading from 2.x](#upgrading-from-2x)
- [Uninstalling](#uninstalling)
- [Changelog](#changelog)

## Features

- **Uses your existing Redmine LDAP authentication mode.** No second set of LDAP credentials to maintain.
- **Group picker:** choose exactly which AD groups appear in Redmine with **+ Add**; removing a group deletes its Redmine group.
- **Nested groups count everywhere.** A member of a group inside a synced group is a member of the synced group.
- **Admin group:** members of one AD group become Redmine administrators; everyone else from AD loses admin rights.
- **Sync at login:** a user's group memberships and admin rights are refreshed every time they log in.
- **Dry run:** preview every change in the log before applying it.
- **Safe on failure:** if AD can't be read, nothing is changed; a login never fails because of the plugin.
- **Email report** after each sync, optionally only when something changed.

## Requirements

- **Redmine 6.1** (tested on 6.1.4 with Rails 7.2). Older Redmine versions are not tested.
- **Microsoft Active Directory or Samba AD.** The plugin uses AD-specific features (`objectGUID` and the nested-membership matching rule `1.2.840.113556.1.4.1941`), so a plain OpenLDAP server will not work.
- **An LDAP authentication mode in Redmine** (*Administration → LDAP authentication*) that binds with a fixed service account. Read-only rights are enough. An account using the `$login` placeholder is not supported.
- **LDAPS is recommended**, and required by Samba AD's default settings (see [Troubleshooting](#troubleshooting)).

## Installation

The plugin directory **must** be named `ldap_sync_groups`.

```bash
cd /path/to/redmine
git clone https://github.com/rupicapra-rupicapra-tatrica/LDAP-Sync-Groups-Plugin-for-Redmine.git plugins/ldap_sync_groups
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

Then restart Redmine (for example `touch tmp/restart.txt` with Passenger, or restart the application server or container).

## Configuration

Go to **Administration → LDAP Sync Groups**.

### 1. LDAP authentication mode

Select the LDAP authentication mode the plugin should use. The plugin connects exactly as Redmine does for that mode: same host, port, LDAPS setting, certificate check, timeout, Base DN and login attribute. **Current LDAP Configuration** shows what is in use.

Only users below the mode's **Base DN** are synced, and they are matched to Redmine users by login (not case-sensitive).

### 2. Groups DN (optional)

Narrows the **+ Add** dropdown to groups in one OU, for example `OU=Groups,DC=example,DC=com`. Leave it empty to list every group in the domain. It does not decide what gets synced; the Synced Groups list does.

### 3. Admin group (optional)

Pick an AD group from the dropdown, which lists every group in the domain. Its members, including members of nested groups, become Redmine administrators. All other users of the selected LDAP authentication mode lose admin rights.

- **Local accounts and users of other authentication modes are never changed.** Keep a local administrator account, such as Redmine's built-in `admin`, as your way back in.
- The plugin never removes admin rights if that would leave Redmine without an active administrator.
- If the admin group can't be found in AD, admin rights are left unchanged and an error is logged.
- The group is stored by its AD ID (`objectGUID`), so renaming or moving it in AD doesn't break the setting.
- Choose **None** to stop managing admin rights. Existing admins keep their rights.

Redmine itself emails a security notification to all administrators whenever someone gains or loses admin rights. If *Two-factor authentication* is set to *required for administrators* (*Administration → Settings → Authentication*), newly granted administrators are asked to set up 2FA at their next login.

### 4. Synced groups

Choose a group in the dropdown under **Synced Groups** and click **+ Add**.

- The Redmine group is created immediately with the AD group's name. Its members are filled in at the next sync.
- If a Redmine group with that name already exists, it is taken over: from the next sync its members are exactly the AD members.
- **✖ Remove** stops syncing the group and **deletes its Redmine group**, including project memberships given through it. You are asked to confirm.
- Nothing is synced until you add at least one group.

Each Redmine group is linked to its AD group by `objectGUID`. When a group is renamed in AD, the Redmine group is renamed at the next sync.

### 5. Email report and logging

- **Report Email:** where to send a report after each sync. Leave empty for no report.
- **Send report only when changes are detected:** skip the report when nothing changed.
- **Verbose Logging:** store every log line, not just changes and summaries.

Click **Save Settings**.

## What a sync does

### Full sync

Started from the admin page or from cron. It runs these steps in order:

1. **Groups.** For every synced group, the Redmine group's members are made exactly the AD group's members, nested members included. Redmine users not in the AD group are removed from it, even if they were added by hand. Groups that were renamed in AD are renamed; Redmine groups deleted by hand are recreated.
2. **Admin rights.** If an admin group is set, admin rights are granted and removed as described under [Admin group](#3-admin-group-optional).

### Sync at login

Every time a user of the selected LDAP authentication mode logs in, their membership in the synced groups and their admin rights are updated from AD. This includes users that Redmine creates automatically at their first login (*On-the-fly user creation* in the authentication mode), so they get their groups and rights straight away.

- The AD lookups are limited to 10 seconds. If AD can't be reached, the login still succeeds and the error is logged.
- Groups are not created at login, and groups missing from AD are left alone.

### Safety rules

- Every directory read either succeeds or stops the step. A failed lookup is never treated as "no members", so a group is never emptied because AD was unreachable.
- A synced group that no longer exists in AD is skipped and logged, never deleted automatically. The page marks it **Not found in AD**; remove it yourself when you're sure.
- If AD can't be reached at all, the sync stops before changing anything and the page shows **Sync failed** with the reason.

## Running a sync

### From the admin page

- **🔍 Run Dry Run (Test):** shows every change a live sync would make, without making it. Dry-run log entries are marked `🔍 DRY RUN` and highlighted. **Run this first after changing the admin group or the synced groups.**
- **▶ Run Live Sync:** applies the changes, after a confirmation.

### From cron

```bash
# Live sync every hour
0 * * * * cd /path/to/redmine && bundle exec bin/rails runner -e production 'LdapSyncService.new(false).run' >> log/ldap_sync.log 2>&1

# Dry run, for example to check the output before enabling the live job
cd /path/to/redmine && bundle exec bin/rails runner -e production 'LdapSyncService.new(true).run'
```

The command exits with a non-zero status when the sync fails (for example when AD is unreachable), so your monitoring can pick it up.

## Logs and reports

- The admin page shows the latest 100 log entries. Errors and deleted groups are red, additions and new groups green, admin changes purple, and dry-run entries highlighted. **🗑 Clear Logs** deletes them all.
- Login syncs log only actual changes, marked `(at login)`, and errors as `Login sync for <login> failed: …`.
- The email report lists the statistics and every change of a full sync, including errors. Login syncs don't send reports.

## Troubleshooting

| Message or symptom | Cause and fix |
|---|---|
| `Stronger Auth Needed (code 8)` | The domain controller refuses unencrypted binds. In the LDAP authentication mode, switch to LDAPS (usually port 636). |
| Certificate errors with LDAPS | For a self-signed certificate, choose *LDAPS (without certificate check)* in the authentication mode, or install the CA certificate on the Redmine server and keep the check on. |
| `Invalid Credentials (code 49)` | Check the account and password in the LDAP authentication mode. |
| `No Such Object (code 32)` | The Base DN or Groups DN doesn't exist. Check for typos. |
| `Connection timed out` | Redmine can't reach the domain controller. Check the host, port and firewall. |
| A user isn't added to a group | The user must already exist in Redmine with the same login as in AD, sit below the Base DN, and be a person account. The plugin doesn't create users; enable *On-the-fly user creation* in the authentication mode to create them at first login. Membership through a user's *primary group* (normally *Domain Users*) isn't visible to LDAP and doesn't count. |
| `Admin rights not revoked … would be left without an active admin` | The change would remove the last active administrator. Make sure a local administrator account exists and is active. |
| `AD group … not found` / **Not found in AD** | The group was deleted in AD. Remove it from the Synced Groups list. |
| `not verifying SSL hostname` in the Redmine log | Printed by the LDAP library when certificate checks are off. It's harmless. |

To test the connection from the command line:

```bash
cd /path/to/redmine
bundle exec bin/rails runner -e production '
auth = AuthSourceLdap.find(LdapSetting.get("ldap_auth_id").to_i)
dir = LdapSyncGroups::Directory.from_auth_source(auth)
dir.open do
  puts "Connected. Domain: #{dir.naming_context}"
  puts "Groups in domain: #{dir.groups(dir.naming_context).size}"
end'
```

## Limitations

- Works with one LDAP authentication mode at a time.
- Doesn't create or delete Redmine users.
- Doesn't lock or unlock Redmine users. Disabling an account in AD stops new logins, because Redmine checks the password against AD, but existing sessions, *Stay logged in* cookies and API keys keep working until you lock the user in Redmine.
- Group membership changes in AD reach Redmine at the next full sync, or at the user's next login.
- Membership through a user's primary group (normally *Domain Users*) isn't detected.
- Redmine group names are unique. Two AD groups with the same name in different OUs can't both be synced.

## Upgrading from 2.x

1. Replace the plugin directory with the new version, then run the migration and restart Redmine:
   ```bash
   bundle exec rake redmine:plugins:migrate RAILS_ENV=production
   ```
2. **The group prefix setting is gone, and Groups DN no longer decides what is synced.** Until you add groups under **Synced Groups**, no groups are synced. Adding an AD group whose Redmine group already exists takes over that group, so existing project memberships are kept.
3. **Users are no longer locked or unlocked.** Users locked by version 2.x stay locked; unlock them in *Administration → Users* if needed.
4. Run a dry run, check the log, then run a live sync.

## Uninstalling

```bash
cd /path/to/redmine
bundle exec rake redmine:plugins:migrate NAME=ldap_sync_groups VERSION=0 RAILS_ENV=production
rm -rf plugins/ldap_sync_groups
```

Then restart Redmine. This removes the plugin's settings, logs and list of synced groups. Redmine users, groups and admin rights stay as they are.

## Changelog

### 3.0.0

- Group picker: choose the synced AD groups with **+ Add**; removing a group deletes its Redmine group. Replaces the group prefix filter; Groups DN now only narrows the dropdown.
- Admin group: members of a chosen AD group become Redmine administrators, with safeguards against locking everyone out.
- Sync at login: group memberships and admin rights are refreshed whenever a user logs in.
- Nested AD groups count as membership everywhere.
- Groups are linked to AD by `objectGUID` and follow renames in AD.
- A failed AD lookup no longer empties a group; a failed connection shows *Sync failed* instead of a success message.
- Uses the authentication mode's LDAPS, certificate and timeout settings instead of guessing from the port.
- Dry runs show every would-be change in the log.
- Computer accounts in AD groups are ignored.
- Removed: locking and unlocking users based on their AD account status.

### 2.0

- Uses the existing Redmine LDAP authentication mode.
- Improved member resolution, logging and debugging.
- Optional group prefix filter.

### 1.0

- Initial release.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
