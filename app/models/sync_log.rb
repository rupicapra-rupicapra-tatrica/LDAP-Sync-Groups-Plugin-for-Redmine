class SyncLog < ActiveRecord::Base
  self.table_name = 'sync_logs'
  
  scope :recent, -> { order(created_at: :desc).limit(100) }
  scope :errors, -> { where("message LIKE ?", "%ERROR%") }
  scope :changes, -> { where("message LIKE ? OR message LIKE ?", "%ADD%", "%REMOVE%") }
  
  def self.add(message, level = 'info')
    # Don't log verbose member details unless they are changes
    if message.include?('Member DN:') || 
       (message.include?('CN:') && !message.include?('ADD') && !message.include?('REMOVE'))
      # Skip verbose member details unless they contain changes
      return unless LdapSetting.get('verbose_logging') == 'true'
    end
    
    create(message: message, level: level)
  end
  
  def self.clear_old(days = 30)
    where('created_at < ?', days.days.ago).delete_all
  end
end
