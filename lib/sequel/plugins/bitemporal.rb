module Sequel
  module Plugins
    module Bitemporal
      class ColumnMissingError < StandardError; end
      def self.configure(model, opts = {})
        master = opts[:master]
        raise ArgumentError, "please specify master class to use for bitemporality" unless master
        required = [:master_id, :valid_from, :valid_to, :created_at, :expired_at]
        missing = required - model.columns
        raise ColumnMissingError, "bitemporal plugin requires the following missing column#{"s" if missing.size>1}: #{missing.join(", ")}" unless missing.empty?
        model.many_to_one :master, class: master, :key => :master_id
        master.one_to_many :versions, class: model, :key => :master_id
        model.instance_eval do
          @bitemporal = true
          @master_class = master
        end
      end
      module ClassMethods
        attr_reader :master_class
        attr_reader :bitemporal
      end
      module DatasetMethods
      end
      module InstanceMethods

        def master
          if master_id
            super
          else
            @new_master ||= model.master_class.new
          end
        end

        def master=(value)
          if value.new?
            self.master_id = nil
            @new_master = value
          else
            @new_master = nil
            super
          end
        end

        def validate
          super
          if model.bitemporal
            errors.add(:valid_from, "is required") unless valid_from
            errors.add(:master, "is not valid") unless master_id || master.valid?
          end
        end
        
        def current?
          now = Time.now
          created_at &&
          created_at.to_time<=now &&
          (expired_at.nil? || expired_at.to_time>now) &&
          valid_from &&
          valid_from.to_time<=now &&
          (valid_to.nil? || valid_to.to_time>now)
        end

     private

        def before_create
          if model.bitemporal
            self.created_at ||= Time.now
            unless master_id
              return false unless @new_master.save
              self.master = @new_master
            end
          end
          super
        end
        
        def before_update
          if model.bitemporal
            now = Time.now
            self.created_at = now
            self.valid_from = now if valid_from.to_time<now
            previous = model.new
            previous.send :set_values, @original_values.dup
            previous.id = nil
            if previous.valid_from<valid_from
              fossil = model.new
              fossil.send :set_values, previous.values.dup
              fossil.created_at = now
              fossil.valid_to = valid_from
              return false unless fossil.save
            end
            previous.expired_at = now
            return false unless previous.save
          end
          super
        end

        def set_values(hash)
          @original_values = hash.dup
          super
        end

      end
    end
  end
end