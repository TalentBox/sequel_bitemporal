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

      def self.bitemporal_excluded_columns
        @bitemporal_excluded_columns ||= [:id, *bitemporal_version_columns]
      end

      def self.configure(master, opts = {})
        version = opts[:version_class]
        raise Error, "please specify version class to use for bitemporal plugin" unless version
        return version.db.log_info("Version table does not exist for #{version.name}") unless version.db.table_exists?(version.table_name)
        missing = bitemporal_version_columns - version.columns
        raise Error, "bitemporal plugin requires the following missing column#{"s" if missing.size>1} on version class: #{missing.join(", ")}" unless missing.empty?

        if Sequel::Plugins::Bitemporal.jdbc?(master.db)
          master.plugin :typecast_on_load, *master.columns
        end

        # Sequel::Model.def_dataset_method has been deprecated and moved to the
        # def_dataset_method plugin in Sequel 4.46.0, it was not loaded by
        # default from 5.0
        begin
          master.plugin :def_dataset_method
        rescue LoadError
        end
        # Sequel::Model#set_all has been deprecated and moved to the whitelist
        # security plugin in Sequel 4.46.0, it was not loaded by default from 5.0
        begin
          master.plugin :whitelist_security
          version.plugin :whitelist_security
        rescue LoadError
        end

        master.instance_eval do
          @version_class = version
          base_alias = opts.fetch :base_alias do
            name ? underscore(demodulize(name)) : table_name
          end
          @versions_alias = "#{base_alias}_versions".to_sym
          @current_version_alias = "#{base_alias}_current_version".to_sym
          @audit_class = opts[:audit_class]
          @audit_updated_by_method = opts.fetch(:audit_updated_by_method){ :updated_by }
          @propagate_per_column = opts.fetch(:propagate_per_column, false)
          @version_uses_string_nilifier = version.plugins.map(&:to_s).include? "Sequel::Plugins::StringNilifier"
          @excluded_columns = Sequel::Plugins::Bitemporal.bitemporal_excluded_columns
          @excluded_columns += Array opts[:excluded_columns] if opts[:excluded_columns]
          @use_ranges = if opts[:ranges]
            db = self.db
            unless db.database_type==:postgres && db.server_version >= 90200
              raise "Ranges require PostgreSQL 9.2"
            end
            true
          else
            false
          end
        end
        master.class_eval do
          def self.current_versions_dataset
            t = ::Sequel::Plugins::Bitemporal.point_in_time
            n = ::Sequel::Plugins::Bitemporal.now
            version_class.where do
              (created_at <= t) &
              (Sequel.|({expired_at=>nil}, expired_at > t)) &
              (valid_from <= n) &
              (valid_to > n)
            end
          end
        end
        master.one_to_many :versions, class: version, key: :master_id, graph_alias_base: master.versions_alias
        master.one_to_one :current_version, class: version, key: :master_id, graph_alias_base: master.current_version_alias, :graph_block=>(proc do |j, lj, js|
          t = Sequel.delay{ ::Sequel::Plugins::Bitemporal.point_in_time }
          n = Sequel.delay{ ::Sequel::Plugins::Bitemporal.now }
          if master.use_ranges
            master.existence_range_contains(t, j) &
            master.validity_range_contains(n, j)
          else
            e = Sequel.qualify j, :expired_at
            (Sequel.qualify(j, :created_at) <= t) &
            (Sequel.|({e=>nil}, e > t)) &
            (Sequel.qualify(j, :valid_from) <= n) &
            (Sequel.qualify(j, :valid_to) > n)
          end
        end) do |ds|
          t = Sequel.delay{ ::Sequel::Plugins::Bitemporal.point_in_time }
          n = Sequel.delay{ ::Sequel::Plugins::Bitemporal.now }
          if master.use_ranges
            ds.where(master.existence_range_contains(t) & master.validity_range_contains(n))
          else
            ds.where do
              (created_at <= t) &
              (Sequel.|({expired_at=>nil}, expired_at > t)) &
              (valid_from <= n) &
              (valid_to > n)
            end
          end
        end
        master.def_dataset_method :with_current_version do
          eager_graph(:current_version).where(
            Sequel.negate(
              Sequel.qualify(model.current_version_alias, :id) => nil
            )
          )
        end
        master.one_to_many :current_or_future_versions, class: version, key: :master_id, :graph_block=>(proc do |j, lj, js|
          t = Sequel.delay{ ::Sequel::Plugins::Bitemporal.point_in_time }
          n = Sequel.delay{ ::Sequel::Plugins::Bitemporal.now }
          if master.use_ranges
            master.existence_range_contains(t, j) &
            (Sequel.qualify(j, :valid_to) > n) &
            (Sequel.qualify(j, :valid_from) != Sequel.qualify(j, :valid_to))
          else
            e = Sequel.qualify j, :expired_at
            (Sequel.qualify(j, :created_at) <= t) &
            Sequel.|({e=>nil}, e > t) &
            (Sequel.qualify(j, :valid_to) > n) &
            (Sequel.qualify(j, :valid_from) != Sequel.qualify(j, :valid_to))
          end
        end) do |ds|
          t = Sequel.delay{ ::Sequel::Plugins::Bitemporal.point_in_time }
          n = Sequel.delay{ ::Sequel::Plugins::Bitemporal.now }
          if master.use_ranges
            existence_conditions = master.existence_range_contains t
            ds.where{ existence_conditions & (:valid_to > n) & (:valid_from != :valid_to) }
          else
            ds.where do
              (created_at <= t) &
              Sequel.|({expired_at=>nil}, expired_at > t) &
              (valid_to > n) &
              (valid_from != valid_to)
            end
          end
        end
        master.def_dataset_method :with_current_or_future_versions do
          eager_graph(:current_or_future_versions).where(
            Sequel.negate(Sequel.qualify(:current_or_future_versions, :id) => nil)
          )
        end
        version.many_to_one :master, class: master, key: :master_id
        version.class_eval do
          if Sequel::Plugins::Bitemporal.jdbc?(master.db)
            plugin :typecast_on_load, *columns
          end

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
          (version.columns-master.columns-master.excluded_columns).each do |column|
            master.class_eval <<-EOS, __FILE__, __LINE__ + 1
              def #{column}
                pending_or_current_version.#{column} if pending_or_current_version
              end
            EOS
          end
        end
        if opts[:writers]
          (version.columns-master.columns-master.excluded_columns).each do |column|
            master.class_eval <<-EOS, __FILE__, __LINE__ + 1
              def #{column}=(value)
                self.attributes = {"#{column}" => value}
              end
            EOS
          end
        end
      end
      module ClassMethods
        attr_reader :version_class, :versions_alias, :current_version_alias,
          :propagate_per_column, :audit_class, :audit_updated_by_method,
          :version_uses_string_nilifier, :use_ranges, :excluded_columns

        def validity_range_type
          @validity_range_type ||= begin
            valid_from_infos = db.schema(
              version_class.table_name
            ).detect do |column_name, _|
              column_name==:valid_from
            end
            unless valid_from_infos
              raise "Could not find valid_from column in #{version_class.table_name}"
            end
            case valid_from_infos.last[:db_type]
            when "date"
              :daterange
            when "timestamp without time zone"
              :tsrange
            when "timestamp with time zone"
              :tstzrange
            else
              raise "Don't know how to handle ranges for type: #{valid_from_infos[:db_type]}"
            end
          end
        end

        def validity_cast_type
          case validity_range_type
          when :daterange
            :date
          when :tsrange, :tstzrange
            :timestamp
          else
            raise "Don't know how to handle cast for range type: #{validity_range_type}"
          end
        end

        def existence_range(qualifier=nil)
          created_at_column = :created_at
          created_at_column = Sequel.qualify qualifier, created_at_column if qualifier
          expired_at_column = :expired_at
          expired_at_column = Sequel.qualify qualifier, expired_at_column if qualifier
          Sequel.function(
            :tsrange, created_at_column, expired_at_column, "[)"
          ).pg_range
        end

        def existence_range_contains(point_in_time, qualifier=nil)
          existence_range(qualifier).contains(
            Sequel.cast(point_in_time, :timestamp)
          )
        end

        def validity_range(qualifier=nil)
          valid_from_column = :valid_from
          valid_from_column = Sequel.qualify qualifier, valid_from_column if qualifier
          valid_to_column = :valid_to
          valid_to_column = Sequel.qualify qualifier, valid_to_column if qualifier

          Sequel.function(
            validity_range_type, valid_from_column, valid_to_column, "[)"
          ).pg_range
        end

        def validity_range_contains(now, qualifier=nil)
          validity_range(qualifier).contains(
            Sequel.cast(now, validity_cast_type)
          )
        end
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
          end if pending_version_holds_changes? && !pending_version.valid?
        end

        def pending_or_current_version
          pending_version || current_version || initial_version
        end

        def attributes
          if pending_version
            pending_version.values
          elsif current_version
            current_version.values
          else
            initial_version.values
          end
        end

        def attributes=(attributes)
          @pending_version ||= begin
            current_attributes = {master_id: id}
            current_version.keys.each do |key|
              next if excluded_columns.include? key
              current_attributes[key] = current_version.send key
            end if current_version?
            model.version_class.new current_attributes
          end
          pending_version.set_all attributes
        end

        def update_attributes(attributes={})
          self.attributes = attributes
          if save raise_on_failure: false
            self
          else
            false
          end
        end

        def before_create
          @create_version = pending_version_holds_changes?
          super
        end

        def after_create
          super
          if @create_version
            @create_version = nil
            return false unless save_pending_version
          end
        end

        def before_update
          if pending_version_holds_changes?
            expire_previous_versions
            return false unless save_pending_version
          end
          super
        end

        def after_save
          super
          _refresh_set_values @values
        end

        def destroy
          point_in_time = ::Sequel::Plugins::Bitemporal.point_in_time
          versions_dataset.where(
            expired_at: nil
          ).where(
            Sequel.lit("valid_to>valid_from")
          ).update expired_at: point_in_time
        end

        def destroy_version(version, expand_previous_version)
          now = ::Sequel::Plugins::Bitemporal.now
          point_in_time = ::Sequel::Plugins::Bitemporal.point_in_time
          return false if version.valid_to.to_datetime<=now
          associations.delete :current_version
          model.db.transaction do
            success = true
            version_was_valid = now>=version.valid_from.to_datetime
            if expand_previous_version
              previous = versions_dataset.where({
                expired_at: nil,
                valid_to: version.valid_from,
              }).where(Sequel.lit("valid_to>valid_from")).first
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

        def deleted?
          !new? && !current_version
        end

        def last_version
          @last_version ||= begin
            return if new?
            t = ::Sequel::Plugins::Bitemporal.point_in_time
            n = ::Sequel::Plugins::Bitemporal.now
            if use_ranges = self.class.use_ranges
              range_conditions = self.class.existence_range_contains t
            end
            versions_dataset.where do
              if use_ranges
                range_conditions
              else
                (created_at <= t) &
                Sequel.|({expired_at=>nil}, expired_at > t)
              end & (valid_from <= n)
            end.order(Sequel.desc(:valid_to), Sequel.desc(:created_at)).first
          end
        end

        def next_version
          @next_version ||= begin
            return if new?
            t = ::Sequel::Plugins::Bitemporal.point_in_time
            n = ::Sequel::Plugins::Bitemporal.now
            if use_ranges = self.class.use_ranges
              range_conditions = self.class.existence_range_contains t
            end
            versions_dataset.where do
              if use_ranges
                range_conditions
              else
                (created_at <= t) &
                Sequel.|({expired_at=>nil}, expired_at > t)
              end & (valid_from > n)
            end.order(Sequel.asc(:valid_to), Sequel.desc(:created_at)).first
          end
        end

        def restore(attrs={})
          return false unless deleted?
          last_version_attributes = if last_version
            last_version.columns.each_with_object({}) do |column, hash|
              unless excluded_columns.include? column
                hash[column] = last_version.send column
              end
            end
          else
            {}
          end
          update_attributes last_version_attributes.merge attrs
          @last_version = nil
        end

        def reload
          @last_version = nil
          @current_version_values = nil
          @pending_version = nil
          @initial_version = nil
          super
        end

        def propagated_during_last_save
          @propagated_during_last_save ||= []
        end

      private

        def prepare_pending_version
          return unless pending_version_holds_changes?
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
          expired = expired.exclude Sequel.lit("valid_from=valid_to")
          expired = expired.exclude Sequel.lit("valid_to<=?", pending_version.valid_from)
          pending_version.valid_to ||= expired.where(Sequel.lit("valid_from>?", pending_version.valid_from)).min(:valid_from)
          pending_version.valid_to ||= Time.utc 9999
          expired = expired.exclude Sequel.lit("valid_from>=?", pending_version.valid_to)
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
          @propagated_during_last_save = []
          lock!
          futures = versions_dataset.where expired_at: nil
          futures = futures.exclude Sequel.lit("valid_from=valid_to")
          futures = futures.exclude Sequel.lit("valid_to<=?", pending_version.valid_from)
          futures = futures.where Sequel.lit("valid_from>?", pending_version.valid_from)
          futures = futures.order(:valid_from).all

          to_check_columns = self.class.version_class.columns - excluded_columns
          updated_by = (send(self.class.audit_updated_by_method) if audited?)
          previous_values = @current_version_values || {}
          current_version_values = {}
          columns = pending_version.columns - excluded_columns_for_changes
          columns.each do |column|
            current_version_values[column] = pending_version.public_send(column)
          end

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
              if !propagated.new? && audited? && updated_by
                self.class.audit_class.audit(
                  self,
                  future_version.values,
                  propagated.values,
                  propagated.valid_from,
                  updated_by
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
            if audited?
              updated_by = send(self.class.audit_updated_by_method)
              self.class.audit_class.audit(
                self,
                current_values_for_audit,
                pending_version.values,
                pending_version.valid_from,
                updated_by
              ) if updated_by
            end
            propagate_changes_to_future_versions
            @current_version_values = nil
            @pending_version = nil
          end
          success
        end

        def save_fossil(expired, attributes={})
          fossil = model.version_class.new
          expired_attributes = expired.keys.each_with_object({}) do |key, hash|
            hash[key] = expired.send key
          end
          expired_attributes.delete :id
          fossil.set_all expired_attributes.merge(attributes)
          fossil.save validate: false
          fossil.send :_refresh_set_values, fossil.values
        end

        def save_propagated(version, attributes={})
          propagated = model.version_class.new
          version_attributes = version.keys.each_with_object({}) do |key, hash|
            hash[key] = version.send key
          end
          version_attributes.delete :id
          version_attributes[:created_at] = Sequel::Plugins::Bitemporal.point_in_time
          propagated.set_all version_attributes.merge(attributes)
          propagated.save validate: false
          propagated.send :_refresh_set_values, propagated.values
          propagated_during_last_save << propagated
          propagated
        end

        def current_version?
          !new? && current_version
        end

        def pending_version_holds_changes?
          return false unless @pending_version
          return true unless current_version?
          @current_version_values = current_version.values
          columns = pending_version.columns - excluded_columns_for_changes
          columns.detect do |column|
            new_value = pending_version.send column
            case column
            when :id, :master_id, :created_at, :expired_at
              false
            when :valid_from
              pending_version.values.has_key?(:valid_from) && (
                new_value<current_version.valid_from ||
                (
                  current_version.valid_to &&
                  new_value>current_version.valid_to
                )
              )
            when :valid_to
              pending_version.values.has_key?(:valid_to) &&
                new_value!=current_version.valid_to
            else
              if model.version_uses_string_nilifier
                if current_version.respond_to? :nil_string?
                  new_value = nil if current_version.nil_string? column, new_value
                elsif !model.version_class.skip_input_transformer?(:string_nilifier, column)
                  new_value = model.version_class.input_transformers[:string_nilifier].call(new_value)
                end
              end
              current_version.send(column)!=new_value
            end
          end
        end

        def excluded_columns
          self.class.excluded_columns
        end

        def excluded_columns_for_changes
          []
        end

        def initial_version
          @initial_version ||= model.version_class.new
        end

      end
    end
  end
end
