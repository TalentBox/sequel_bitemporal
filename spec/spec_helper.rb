require "sequel"
require "timecop"

Dir[File.expand_path("../support/*.rb", __FILE__)].each{|f| require f}
ENV["TZ"]="UTC"

require "sequel_bitemporal"
Sequel::Deprecation.output = false

rspec_exclusions = {}

DB = if DbHelpers.pg?
  `createdb sequel_bitemporal_test`
  Sequel.extension :pg_range, :pg_range_ops
  Sequel.connect DbHelpers.pg_ruby_connect_uri
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
  config.filter_run_excluding rspec_exclusions
  config.disable_monkey_patching!
  config.before :each do
    db_truncate
  end
end
