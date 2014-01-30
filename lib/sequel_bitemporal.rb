require "sequel"

module Sequel
  module Plugins
    module Bitemporal
      def self.jruby?
        (defined?(RUBY_ENGINE) && RUBY_ENGINE == 'jruby') || defined?(JRUBY_VERSION)
      end
    end
  end
end

require "sequel/plugins/bitemporal"
