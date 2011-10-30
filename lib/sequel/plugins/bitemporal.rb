module Sequel
  module Plugins
    module Bitemporal
      class ColumnMissingError < StandardError; end
      def self.configure(model, opts = {})
        required = [:master_id, :valid_from, :valid_to, :created_at, :expired_at]
        missing = required - model.columns
        raise ColumnMissingError, "bitemporal plugin requires the following missing column#{"s" if missing.size>1}: #{missing.join(", ")}" unless missing.empty?
      end
      module ClassMethods
      end
      module DatasetMethods
      end
      module InstanceMethods

        # Set the create timestamp when creating
        def set_created_at_and_valid_at
          set_create_timestamp
          super
        end
        
        # Set the update timestamp when updating
        def set_created_at_and_valid_at
          set_update_timestamp
          super
        end

      private
      
        def set_created_at_and_valid_at
          self.created_at = Time.now
          self.valid_from ||= Time.now
        end
      
      end
    end
  end
end