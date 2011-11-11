module Sequel
  module Plugins
    module Bitemporal
      def self.as_we_knew_it(time)
        raise ArgumentError, "requires a block" unless block_given?
        previous_point_in_time, @point_in_time = @point_in_time, time
        yield
        @point_in_time = previous_point_in_time
      end
      
      def self.point_in_time
        @point_in_time || Time.now
      end

      def self.configure(master, opts = {})
        version = opts[:version_class]
        raise Error, "please specify version class to use for bitemporal plugin" unless version
        required = [:master_id, :valid_from, :valid_to, :created_at, :expired_at]
        missing = required - version.columns
        raise Error, "bitemporal plugin requires the following missing column#{"s" if missing.size>1} on version class: #{missing.join(", ")}" unless missing.empty?
        master.one_to_many :versions, class: version, key: :master_id
        master.one_to_one :current_version, class: version, key: :master_id, :graph_block=>(proc do |j, lj, js|
          t = ::Sequel::Plugins::Bitemporal.point_in_time
          e = :expired_at.qualify(j)
          (:created_at.qualify(j) <= t) & ({e=>nil} | (e > t)) & (:valid_from.qualify(j) <= t) & (:valid_to.qualify(j) > t)
        end) do |ds|
          t = ::Sequel::Plugins::Bitemporal.point_in_time
          ds.where{(created_at <= t) & ({expired_at=>nil} | (expired_at > t)) & (valid_from <= t) & (valid_to > t)}
        end
        master.def_dataset_method :with_current_version do
          eager_graph(:current_version).where({current_version__id: nil}.sql_negate)
        end
        master.one_to_many :current_or_future_versions, class: version, key: :master_id, :graph_block=>(proc do |j, lj, js|
          t = ::Sequel::Plugins::Bitemporal.point_in_time
          e = :expired_at.qualify(j)
          (:created_at.qualify(j) <= t) & ({e=>nil} | (e > t)) & (:valid_to.qualify(j) > t)
        end) do |ds|
          t = ::Sequel::Plugins::Bitemporal.point_in_time
          ds.where{(created_at <= t) & ({expired_at=>nil} | (expired_at > t)) & (valid_to > t)}
        end
        master.def_dataset_method :with_current_or_future_versions do
          eager_graph(:current_or_future_versions).where({current_or_future_versions__id: nil}.sql_negate)
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

        def before_validation
          prepare_pending_version
          super
        end

        def validate
          super
          pending_version.errors.each do |key, key_errors|
            key_errors.each{|error| errors.add key, error}
          end if pending_version && !pending_version.valid?
        end
        
        def pending_or_current_version
          pending_version || current_version
        end

        def attributes
          if pending_version
            pending_version.values
          elsif current_version
            current_version.values
          else
            {}
          end
        end

        def attributes=(attributes)
          if !new? && attributes.delete(:partial_update) && current_version
            current_attributes = current_version.values.dup
            current_attributes.delete :valid_from
            attributes = current_attributes.merge attributes
          end
          attributes.delete :id
          @pending_version ||= model.version_class.new
          pending_version.set attributes
          pending_version.master_id = id unless new?
        end

        def update_attributes(attributes={})
          self.attributes = attributes
          save raise_on_failure: false
        end

        def after_create
          super
          if pending_version
            return false unless save_pending_version
          end
        end

        def before_update
          if pending_version
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
          return unless pending_version
          point_in_time = Time.now
          pending_version.created_at = point_in_time
          pending_version.valid_from ||= point_in_time
        end

        def expire_previous_versions
          lock!
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

        def save_pending_version
          pending_version.valid_to ||= Time.utc 9999
          success = add_version pending_version
          @pending_version = nil if success
          success
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