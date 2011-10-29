require "spec_helper"

describe "Bitemporal plugin" do

  def klass(table_name, &block)
    @db = MODEL_DB
    c = Class.new(Sequel::Model(@db[:hotel_rooms]))
    c.class_eval &block
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

  let :version_class do
    master_class = klass :rooms do
      columns :id
    end
    klass :room_versions do
      columns :id, :master_id, :name, :price, :created_at, :expired_at, :valid_from, :valid_to, :state
      plugin :bitemporal, master: master_class
    end
  end

  def check_versions(table)
    puts table.inspect
  end

  before{ Timecop.freeze 2009, 11, 28 }
  after{ Timecop.return }

  it "fills in created_at and valid_from" do
    version_class.create name: "Single Standard", price: 98
    check_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to | state       |
      | Single Standard | 98.00 | 2009-11-28 |            | 2009-11-28 |          | to_validate |
    }
  end

end
