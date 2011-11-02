module Sequel
  module Plugins
    module Bitemporal
      def self.configure(master, opts = {})
        version = opts[:version_class]
        raise Error, "please specify version class to use for bitemporal plugin" unless version
        required = [:master_id, :valid_from, :valid_to, :created_at, :expired_at]
        missing = required - version.columns
        raise Error, "bitemporal plugin requires the following missing column#{"s" if missing.size>1} on version class: #{missing.join(", ")}" unless missing.empty?
        master.one_to_many :versions, class: version, key: :master_id
        master.one_to_one :current_version, class: version, key: :master_id do |ds|
          ds.where "created_at<=:now AND (expired_at IS NULL OR expired_at>:now) AND valid_from<=:now AND valid_to>:now", now: Time.now
        end
        version.many_to_one :master, class: master, key: :master_id
        version.class_eval do
          def current?(now = Time.now)
            !new? &&
            created_at.to_time<=now &&
            (expired_at.nil? || expired_at.to_time>now) &&
            valid_from.to_time<=now &&
            valid_to.to_time>now
          end
          def destroy
            master.destroy_version self
          end
        end
        master.instance_eval do
          @version_class = version
        end
      end
      module ClassMethods
        attr_reader :version_class
      end
      module DatasetMethods
      end
      module InstanceMethods
        attr_reader :pending_version

        def validate
          super
          pending_version.errors.each do |key, key_errors|
            key_errors.each{|error| errors.add key, error}
          end if pending_version && !pending_version.valid?
        end

        def attributes
          pending_version ? pending_version.values : {}
        end

        def attributes=(attributes)
          @pending_version ||= model.version_class.new
          pending_version.set attributes
        end

        def update_attributes(attributes={})
          if !new? && attributes.delete(:partial_update) && current_version
            current_attributes = current_version.values.dup
            current_attributes.delete :id
            attributes = current_attributes.merge attributes
          end
          self.attributes = attributes
          save raise_on_failure: false
        end

        def after_create
          super
          if pending_version
            prepare_pending_version
            return false unless save_pending_version
          end
        end

        def before_update
          if pending_version
            lock!
            prepare_pending_version
            expire_previous_versions
            return false unless save_pending_version
          end
          super
        end

        def destroy
          versions_dataset.where(expired_at: nil).where("valid_to>valid_from").update expired_at: Time.now
        end

        def destroy_version(version)
          point_in_time = Time.now
          return false if version.valid_to.to_time<=point_in_time
          model.db.transaction do
            success = true
            previous = versions_dataset.where({
              expired_at: nil,
              valid_to: version.valid_from,
            }).where("valid_to>valid_from").first
            if previous
              success &&= save_fossil previous, created_at: point_in_time, valid_to: version.valid_to
              success &&= previous.update expired_at: point_in_time
            end
            success &&= save_fossil version, created_at: point_in_time, valid_to: point_in_time if point_in_time>=version.valid_from.to_time
            success &&= version.update expired_at: point_in_time
            raise Sequel::Rollback unless success
            success
          end
        end

      private

        def prepare_pending_version
          point_in_time = Time.now
          pending_version.created_at = point_in_time
          pending_version.valid_from = point_in_time if !pending_version.valid_from || pending_version.valid_from.to_time<point_in_time
        end

        def save_pending_version
          pending_version.valid_to ||= Time.utc 9999
          success = add_version pending_version
          @pending_version = nil if success
          success
        end

        def expire_previous_versions
          expired = versions_dataset.where expired_at: nil
          expired = expired.exclude "valid_from=valid_to"
          expired = expired.exclude "valid_to<=?", pending_version.valid_from
          pending_version.valid_to ||= expired.where("valid_from>?", pending_version.valid_from).min(:valid_from)
          pending_version.valid_to ||= Time.utc 9999
          expired = expired.exclude "valid_from>=?", pending_version.valid_to
          expired = expired.all
          expired.each do |expired_version|
            if expired_version.valid_from<pending_version.valid_from && expired_version.valid_to>pending_version.valid_from
              return false unless save_fossil expired_version, created_at: pending_version.created_at, valid_to: pending_version.valid_from
            elsif expired_version.valid_from<pending_version.valid_to && expired_version.valid_to>pending_version.valid_to
              return false unless save_fossil expired_version, created_at: pending_version.created_at, valid_from: pending_version.valid_to
            end
          end
          versions_dataset.where(id: expired.collect(&:id)).update expired_at: pending_version.created_at
        end

        def save_fossil(expired, attributes={})
          fossil = model.version_class.new
          expired_attributes = expired.values.dup
          expired_attributes.delete :id
          fossil.send :set_values, expired_attributes.merge(attributes)
          fossil.save validate: false
        end
      end
    end
  end
end