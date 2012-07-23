require "date"

module Sequel
  module Plugins
    module Bitemporal
      THREAD_POINT_IN_TIME_KEY = :sequel_plugins_bitemporal_point_in_time
      def self.as_we_knew_it(time)
        previous = Thread.current[THREAD_POINT_IN_TIME_KEY]
        raise ArgumentError, "requires a block" unless block_given?
        Thread.current[THREAD_POINT_IN_TIME_KEY] = time.to_datetime
        yield
      ensure
        Thread.current[THREAD_POINT_IN_TIME_KEY] = previous
      end

      def self.point_in_time
        Thread.current[THREAD_POINT_IN_TIME_KEY] || DateTime.now
      end

      THREAD_NOW_KEY = :sequel_plugins_bitemporal_now
      def self.at(time)
        previous = Thread.current[THREAD_NOW_KEY]
        raise ArgumentError, "requires a block" unless block_given?
        Thread.current[THREAD_NOW_KEY] = time.to_datetime
        yield
      ensure
        Thread.current[THREAD_NOW_KEY] = previous
      end

      def self.now
        Thread.current[THREAD_NOW_KEY] || DateTime.now
      end

      def self.bitemporal_version_columns
        @bitemporal_version_columns ||= [:master_id, :valid_from, :valid_to, :created_at, :expired_at]
      end

      def self.configure(master, opts = {})
        version = opts[:version_class]
        raise Error, "please specify version class to use for bitemporal plugin" unless version
        missing = bitemporal_version_columns - version.columns
        raise Error, "bitemporal plugin requires the following missing column#{"s" if missing.size>1} on version class: #{missing.join(", ")}" unless missing.empty?
        master.instance_eval do
          @version_class = version
          base_alias = name ? underscore(demodulize(name)) : table_name
          @versions_alias = "#{base_alias}_versions".to_sym
          @current_version_alias = "#{base_alias}_current_version".to_sym
          @audit_class = opts[:audit_class]
          @audit_updated_by_method = opts[:audit_updated_by_method] || :updated_by_id
          @propagate_per_column = opts.fetch(:propagate_per_column, false)
        end
        master.one_to_many :versions, class: version, key: :master_id, graph_alias_base: master.versions_alias
        master.one_to_one :current_version, class: version, key: :master_id, graph_alias_base: master.current_version_alias, :graph_block=>(proc do |j, lj, js|
          t = ::Sequel::Plugins::Bitemporal.point_in_time
          n = ::Sequel::Plugins::Bitemporal.now
          e = :expired_at.qualify(j)
          (:created_at.qualify(j) <= t) & ({e=>nil} | (e > t)) & (:valid_from.qualify(j) <= n) & (:valid_to.qualify(j) > n)
        end) do |ds|
          t = ::Sequel::Plugins::Bitemporal.point_in_time
          n = ::Sequel::Plugins::Bitemporal.now
          ds.where{(created_at <= t) & ({expired_at=>nil} | (expired_at > t)) & (valid_from <= n) & (valid_to > n)}
        end
        master.def_dataset_method :with_current_version do
          eager_graph(:current_version).where({:id.qualify(model.current_version_alias) => nil}.sql_negate)
        end
        master.one_to_many :current_or_future_versions, class: version, key: :master_id, :graph_block=>(proc do |j, lj, js|
          t = ::Sequel::Plugins::Bitemporal.point_in_time
          n = ::Sequel::Plugins::Bitemporal.now
          e = :expired_at.qualify(j)
          (:created_at.qualify(j) <= t) & ({e=>nil} | (e > t)) & (:valid_to.qualify(j) > n)
        end) do |ds|
          t = ::Sequel::Plugins::Bitemporal.point_in_time
          n = ::Sequel::Plugins::Bitemporal.now
          ds.where{(created_at <= t) & ({expired_at=>nil} | (expired_at > t)) & (valid_to > n)}
        end
        master.def_dataset_method :with_current_or_future_versions do
          eager_graph(:current_or_future_versions).where({current_or_future_versions__id: nil}.sql_negate)
        end
        version.many_to_one :master, class: master, key: :master_id
        version.class_eval do
          def current?
            t = ::Sequel::Plugins::Bitemporal.point_in_time
            n = ::Sequel::Plugins::Bitemporal.now
            !new? &&
            created_at.to_datetime<=t &&
            (expired_at.nil? || expired_at.to_datetime>t) &&
            valid_from.to_datetime<=n &&
            valid_to.to_datetime>n
          end
          def destroy(opts={})
            expand_previous_version = opts.fetch(:expand_previous_version){
              valid_from.to_datetime>::Sequel::Plugins::Bitemporal.now
            }
            master.destroy_version self, expand_previous_version
          end
        end
        unless opts[:delegate]==false
          (version.columns-bitemporal_version_columns-[:id]).each do |column|
            master.class_eval <<-EOS
              def #{column}
                pending_or_current_version.#{column} if pending_or_current_version
              end
            EOS
          end
        end
      end
      module ClassMethods
        attr_reader :version_class, :versions_alias, :current_version_alias
        attr_reader :propagate_per_column
        attr_reader :audit_class, :audit_updated_by_method
      end
      module DatasetMethods
      end
      module InstanceMethods
        attr_reader :pending_version

        def audited?
          !!self.class.audit_class
        end

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
          @current_version_values = current_version ? current_version.values : {}
          if attributes.delete(:partial_update) && !@pending_version && !new? && current_version
            current_attributes = current_version.keys.inject({}) do |hash, key|
              hash[key] = current_version.send key
              hash
            end
            current_attributes.delete :valid_from
            current_attributes.delete :valid_to
            attributes = current_attributes.merge attributes
          end
          attributes.delete :id
          @pending_version ||= model.version_class.new
          pending_version.set attributes
          pending_version.master_id = id unless new?
        end

        def update_attributes(attributes={})
          self.attributes = attributes
          save(raise_on_failure: false) && self
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
          point_in_time = ::Sequel::Plugins::Bitemporal.point_in_time
          versions_dataset.where(expired_at: nil).where("valid_to>valid_from").update expired_at: point_in_time
        end

        def destroy_version(version, expand_previous_version)
          now = ::Sequel::Plugins::Bitemporal.now
          point_in_time = ::Sequel::Plugins::Bitemporal.point_in_time
          return false if version.valid_to.to_datetime<=now
          model.db.transaction do
            success = true
            version_was_valid = now>=version.valid_from.to_datetime
            if expand_previous_version
              previous = versions_dataset.where({
                expired_at: nil,
                valid_to: version.valid_from,
              }).where("valid_to>valid_from").first
              if previous
                if version_was_valid
                  success &&= save_fossil previous, created_at: point_in_time, valid_from: now, valid_to: version.valid_to
                else
                  success &&= save_fossil previous, created_at: point_in_time, valid_to: version.valid_to
                  success &&= previous.update expired_at: point_in_time
                end
              end
            end
            success &&= save_fossil version, created_at: point_in_time, valid_to: now if version_was_valid
            success &&= version.update expired_at: point_in_time
            raise Sequel::Rollback unless success
            success
          end
        end

      private

        def prepare_pending_version
          return unless pending_version
          now = ::Sequel::Plugins::Bitemporal.now
          point_in_time = ::Sequel::Plugins::Bitemporal.point_in_time
          pending_version.created_at = point_in_time
          pending_version.valid_from ||= now
        end

        def expire_previous_versions
          master_changes = values.select{|k| changed_columns.include? k}
          lock!
          set master_changes
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

        def propagate_changes_to_future_versions
          return true unless self.class.propagate_per_column
          lock!
          futures = versions_dataset.where expired_at: nil
          futures = futures.exclude "valid_from=valid_to"
          futures = futures.exclude "valid_to<=?", pending_version.valid_from
          futures = futures.where "valid_from>?", pending_version.valid_from
          futures = futures.order(:valid_from).all

          excluded_columns = Sequel::Plugins::Bitemporal.bitemporal_version_columns + [:id]
          to_check_columns = self.class.version_class.columns - excluded_columns
          updated_by = send(self.class.audit_updated_by_method) if audited?
          previous_values = @current_version_values
          current_version_values = pending_version.values

          futures.each do |future_version|
            attrs = {}
            to_check_columns.each do |col|
              if previous_values[col]==future_version[col] &&
                  previous_values[col]!=current_version_values[col]
                attrs[col] = current_version_values[col]
              end
            end
            if attrs.any?
              propagated = save_propagated future_version, attrs
              if !propagated.new? && audited?
                self.class.audit_class.audit(
                  self,
                  future_version.values,
                  propagated.values,
                  propagated.valid_from,
                  send(self.class.audit_updated_by_method)
                )
              end
              previous_values = future_version.values.dup
              current_version_values = propagated.values
              future_version.this.update :expired_at => Sequel::Plugins::Bitemporal.point_in_time
            else
              break
            end
          end
        end

        def save_pending_version
          current_values_for_audit = @current_version_values || {}
          pending_version.valid_to ||= Time.utc 9999
          success = add_version pending_version
          if success
            self.class.audit_class.audit(
              self,
              current_values_for_audit,
              pending_version.values,
              pending_version.valid_from,
              send(self.class.audit_updated_by_method)
            ) if audited?
            propagate_changes_to_future_versions
            @pending_version = nil
          end
          success
        end

        def save_fossil(expired, attributes={})
          fossil = model.version_class.new
          expired_attributes = expired.values.dup
          expired_attributes.delete :id
          fossil.send :set_values, expired_attributes.merge(attributes)
          fossil.save validate: false
        end

        def save_propagated(version, attributes={})
          propagated = model.version_class.new
          version_attributes = version.values.dup
          version_attributes.delete :id
          version_attributes[:created_at] = Sequel::Plugins::Bitemporal.point_in_time
          propagated.send :set_values, version_attributes.merge(attributes)
          propagated.save validate: false
          propagated
        end
      end
    end
  end
end

