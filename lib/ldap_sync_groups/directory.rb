require 'net/ldap'

module LdapSyncGroups
  # Read-only access to the Active Directory behind a Redmine LDAP
  # authentication mode. Group membership is always resolved transitively,
  # so members of nested groups count as members.
  class Directory
    class Error < StandardError; end

    User = Struct.new(:dn, :login, :disabled, keyword_init: true)
    Group = Struct.new(:dn, :name, :guid, keyword_init: true)

    # LDAP_MATCHING_RULE_IN_CHAIN: the server follows nested groups
    IN_CHAIN = '1.2.840.113556.1.4.1941'
    # userAccountControl flag ACCOUNTDISABLE
    UAC_DISABLED = 0x2

    GROUP_FILTER = Net::LDAP::Filter.eq('objectClass', 'group')
    # objectClass=user alone also matches computer accounts
    PERSON_FILTER = Net::LDAP::Filter.eq('objectCategory', 'person') & Net::LDAP::Filter.eq('objectClass', 'user')

    # Connects the same way Redmine does for this authentication mode.
    def self.from_auth_source(auth)
      new(host: auth.host, port: auth.port, tls: auth.tls, verify_peer: auth.verify_peer?,
          bind_dn: auth.account, password: auth.account_password,
          users_base_dn: auth.base_dn, login_attr: auth.attr_login.presence || 'sAMAccountName',
          timeout: auth.timeout)
    end

    def initialize(host:, port:, tls:, verify_peer:, bind_dn:, password:, users_base_dn:,
                   login_attr: 'sAMAccountName', timeout: nil)
      options = { host: host, port: port }
      options[:connect_timeout] = timeout.to_i if timeout.to_i > 0
      if tls
        options[:encryption] = {
          method: :simple_tls,
          tls_options: { verify_mode: verify_peer ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE }
        }
      end
      options[:auth] = { method: :simple, username: bind_dn, password: password } unless bind_dn.to_s.empty?
      @ldap = Net::LDAP.new(options)
      @users_base_dn = users_base_dn
      @login_attr = login_attr
    end

    # Runs the block over a single bound connection and returns its result.
    # Every directory call raises Error on failure instead of returning
    # nothing, so a failed lookup is never mistaken for an empty group.
    def open
      result = nil
      @ldap.open do
        check!("bind to #{@ldap.host}:#{@ldap.port}")
        result = yield self
      end
      result
    rescue Net::LDAP::Error, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      raise Error, "LDAP connection to #{@ldap.host}:#{@ldap.port} failed: #{e.message}"
    end

    # The domain root, e.g. DC=ad,DC=example,DC=com
    def naming_context
      entry = search('', Net::LDAP::Filter.pres('objectClass'), ['defaultNamingContext'], scope: Net::LDAP::SearchScope_BaseObject).first
      entry && entry[:defaultnamingcontext].first
    end

    # All user accounts below the users base DN.
    def users
      search(@users_base_dn, PERSON_FILTER, [@login_attr, 'userAccountControl']).filter_map { |e| to_user(e) }
    end

    def find_user(login)
      filter = PERSON_FILTER & Net::LDAP::Filter.equals(@login_attr, login)
      search(@users_base_dn, filter, [@login_attr, 'userAccountControl']).filter_map { |e| to_user(e) }.first
    end

    # All groups below base, sorted by name.
    def groups(base)
      search(base, GROUP_FILTER, %w[cn objectGUID]).map { |e| to_group(e) }.sort_by { |g| g.name.downcase }
    end

    # Groups below base that the user is a member of, directly or nested.
    def groups_of(user_dn, base)
      filter = GROUP_FILTER & Net::LDAP::Filter.ex("member:#{IN_CHAIN}", Net::LDAP::Filter.escape(user_dn))
      search(base, filter, %w[cn objectGUID]).map { |e| to_group(e) }
    end

    # Logins of the users below the users base DN that are members of the
    # group, directly or nested. Members that are not users are ignored.
    def member_logins(group_dn)
      filter = PERSON_FILTER & Net::LDAP::Filter.ex("memberOf:#{IN_CHAIN}", Net::LDAP::Filter.escape(group_dn))
      search(@users_base_dn, filter, [@login_attr]).filter_map { |e| e[@login_attr].first }
    end

    private

    def search(base, filter, attributes, scope: Net::LDAP::SearchScope_WholeSubtree)
      entries = @ldap.search(base: base, filter: filter, attributes: attributes, scope: scope)
      check!("search in '#{base}'") if entries.nil?
      entries
    end

    def check!(operation)
      result = @ldap.get_operation_result
      return if result.code == 0

      raise Error, "LDAP #{operation} failed: #{result.message} (code #{result.code})"
    end

    def to_user(entry)
      login = entry[@login_attr].first
      return unless login

      uac = entry[:useraccountcontrol].first.to_i
      User.new(dn: entry.dn, login: login, disabled: (uac & UAC_DISABLED) != 0)
    end

    def to_group(entry)
      Group.new(dn: entry.dn, name: entry[:cn].first, guid: format_guid(entry[:objectguid].first))
    end

    # objectGUID is binary with the first three fields little-endian
    def format_guid(raw)
      return unless raw

      b = raw.b
      [b[0, 4].reverse, b[4, 2].reverse, b[6, 2].reverse, b[8, 2], b[10, 6]].map { |part| part.unpack1('H*') }.join('-')
    end
  end
end
