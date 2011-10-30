require "spec_helper"

describe "Bitemporal plugin" do

  def klass(table_name, &block)
    @db = MODEL_DB
    c = Class.new(Sequel::Model(@db[table_name]))
    c.class_eval(&block)
    c.class_eval do
      self.use_transactions = false
      class << self
        attr_accessor :rows
      end
      def checked_transaction(opts={})
        return super if @in_transaction || !use_transaction?(opts)
        @in_transaction = true
        db.execute 'BEGIN'
        super
        db.execute 'COMMIT'
        @in_transaction = false
      end
    end
    c
  end

  describe "configuration" do
    it "checks required columns are present" do
      lambda{
        klass :items do
          columns :id
          plugin :bitemporal
        end
      }.should raise_error "bitemporal plugin requires the following missing columns: master_id, valid_from, valid_to, created_at, expired_at"
      lambda{
        klass :items do
          columns :id, :master_id, :created_at, :updated_at
          plugin :bitemporal
        end
      }.should raise_error "bitemporal plugin requires the following missing columns: valid_from, valid_to, expired_at"
    end
  end

  describe "versioning" do
    def parse_table(str)
      rows = str.strip.split("\n")
      rows.collect!{|row| row[/^\s*\|(.+)\|\s*$/, 1].split("|").collect(&:strip)}
      headers = rows.shift
      rows.collect{|row| Hash[headers.zip row]}
    end
    def check_versions(str)
      table = parse_table str
      puts table.inspect
    end
    let :version_class do
      master_class = klass :rooms do
        columns :id
      end
      klass :room_versions do
        columns :id, :master_id, :name, :price, :created_at, :expired_at, :valid_from, :valid_to, :state
        plugin :bitemporal, master: master_class
      end
    end
    before{ Timecop.freeze 2009, 11, 28; MODEL_DB.reset }
    after{ Timecop.return }

    it "fills in created_at and valid_from" do
      version_class.create name: "Single Standard", price: 98
      check_versions %Q{
        | name            | price | created_at | expired_at | valid_from | valid_to | state       |
        | Single Standard | 98.00 | 2009-11-28 |            | 2009-11-28 |          | to_validate |
      }
    end
  end

end