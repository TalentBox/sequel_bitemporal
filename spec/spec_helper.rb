require "sequel"
require "timecop"
require "pry"

Dir[File.expand_path("../support/*.rb", __FILE__)].each{|f| require f}
ENV["TZ"]="UTC"

DB = if DbHelpers.pg?
  `createdb sequel_bitemporal_test`
  Sequel.extension :pg_range, :pg_range_ops
  Sequel.postgres "sequel_bitemporal_test"
else
  Sequel.sqlite
end

if ENV["DEBUG"]
  require "logger"
  DB.loggers << Logger.new($stdout)
end

RSpec.configure do |config|
  config.include DbHelpers

  config.before :each do
    db_truncate
  end
end
