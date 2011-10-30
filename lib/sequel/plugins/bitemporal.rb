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

        def before_save
          if model.bitemporal
            self.created_at = Time.now
          end
          super
        end

        def before_create
          if model.bitemporal && !master_id
            return false unless @new_master.save
            self.master = @new_master
          end
          super
        end

      end
    end
  end
end