require "sequel"
require "timecop"
require "pry"
DB = Sequel.sqlite
Dir[File.expand_path("../support/*.rb", __FILE__)].each{|f| require f}
