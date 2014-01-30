require "sequel"
require "timecop"
require "pry"

Dir[File.expand_path("../support/*.rb", __FILE__)].each{|f| require f}
ENV["TZ"]="UTC"

require "sequel_bitemporal"

rspec_exclusions = {}

DB = if DbHelpers.pg?
  `createdb sequel_bitemporal_test`
  Sequel.extension :pg_range, :pg_range_ops
  if ::Sequel::Plugins::Bitemporal.jruby?
    Sequel.connect "jdbc:postgresql://localhost/sequel_bitemporal_test"
  else
    Sequel.postgres "sequel_bitemporal_test"
  end
else
  if Sequel::Plugins::Bitemporal.jruby?
    rspec_exclusions[:skip_jdbc_sqlite] = true
    Sequel::Model.plugin :typecast_on_load
    Sequel.connect "jdbc:sqlite::memory:"
  else
    Sequel.sqlite
  end
end

if ENV["DEBUG"]
  require "logger"
  DB.loggers << Logger.new($stdout)
end

RSpec.configure do |config|
  config.include DbHelpers
  config.treat_symbols_as_metadata_keys_with_true_values = true
  config.filter_run_excluding rspec_exclusions
  config.before :each do
    db_truncate
  end
end
