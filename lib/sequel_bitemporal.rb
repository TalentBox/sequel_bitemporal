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
    end
  end
end

require "sequel/plugins/bitemporal"
