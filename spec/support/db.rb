module DbHelpers

  def self.pg?
    ENV.has_key? "PG"
  end

  def db_setup(opts={})
    use_time = opts[:use_time]
    use_audit_tables = opts[:use_audit_tables]
    DB.drop_table(:room_versions) if DB.table_exists?(:room_versions)
    DB.drop_table(:rooms) if DB.table_exists?(:rooms)
    DB.create_table! :rooms do
      primary_key :id
      Boolean     :disabled, null: false, default: false
    end
    DB.create_table! :room_versions do
      primary_key :id
      foreign_key :master_id, :rooms
      String      :name
      Fixnum      :price
      Fixnum      :length
      Fixnum      :width
      send(use_time ? :Time : :Date, :created_at)
      send(use_time ? :Time : :Date, :expired_at)
      send(use_time ? :Time : :Date, :valid_from)
      send(use_time ? :Time : :Date, :valid_to)
    end
    @version_class = Class.new Sequel::Model do
      set_dataset :room_versions
      def validate
        super
        errors.add(:name, "is required") unless name
        errors.add(:price, "is required") unless price
      end
      attr_accessor :updated_by if use_audit_tables
    end

    bitemporal_options = {version_class: @version_class}
    bitemporal_options[:audit_class] = opts[:audit_class] if opts[:audit_class]
    bitemporal_options[:audit_updated_by_method] = opts[:audit_updated_by_method] if opts[:audit_updated_by_method]
    bitemporal_options[:ranges] = opts[:ranges] if opts[:ranges]

    if use_audit_tables
      DB.create_table! :room_audits do
        primary_key :id
        Date        :for
        foreign_key :room_id
      end
      DB.create_table! :room_audit_versions do
        primary_key :id
        foreign_key :master_id, :room_audits
        integer     :name_u_user_id
        send(use_time ? :Time : :Date, :name_at)
        integer     :price_u_user_id
        send(use_time ? :Time : :Date, :price_at)
        integer     :length_u_user_id
        send(use_time ? :Time : :Date, :length_at)
        integer     :width_u_user_id
        send(use_time ? :Time : :Date, :width_at)
        send(use_time ? :Time : :Date, :created_at)
        send(use_time ? :Time : :Date, :expired_at)
        send(use_time ? :Time : :Date, :valid_from)
        send(use_time ? :Time : :Date, :valid_to)
      end
      audit_version_class = @audit_version_class = Class.new Sequel::Model do
        set_dataset :room_audit_versions
        def self.name
          'RoomAuditVersion'
        end
      end
      room_audit_class = @audit_class = Class.new Sequel::Model do
        set_dataset :room_audits
        plugin :bitemporal, version_class: audit_version_class
        plugin :audit_by_day, foreign_key: :room_id, updated_by_regexp: /\A(.+)_u_(.+)_id\z/
        def self.name
          'RoomAudit'
        end
      end
      @master_class = Class.new Sequel::Model do
        set_dataset :rooms
        plugin :bitemporal, bitemporal_options
        def self.audit_class=(klass)
          @audit_class = klass
        end
        def self.audit_class
          @audit_class
        end
        self.audit_class = room_audit_class
        def audits
          self.class.audit_class.where(room_id: id).qualify.order(Sequel.asc(:id)).all
        end
        def self.name
          'Room'
        end
        def updated_by
          pending_or_current_version.updated_by
        end
      end
    else
      @master_class = Class.new Sequel::Model do
        set_dataset :rooms
        plugin :bitemporal, bitemporal_options
      end
    end
  end

  def db_truncate
    if DbHelpers.pg?
      @version_class.truncate cascade: true
      @master_class.truncate cascade: true
    else
      @version_class.truncate
      @master_class.truncate
    end
  end
end
