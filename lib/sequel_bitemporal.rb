require "sequel"

module Sequel
  module Plugins
    module Bitemporal
      def self.jruby?
        (defined?(RUBY_ENGINE) && RUBY_ENGINE == 'jruby') || defined?(JRUBY_VERSION)
      end

      def self.jdbc?(db)
        db.adapter_scheme==:jdbc
      end

      def self.pg_jdbc?(db)
        db.database_type==:postgres && jdbc?(db)
      end
    end
  end
end

require "sequel/plugins/bitemporal"
