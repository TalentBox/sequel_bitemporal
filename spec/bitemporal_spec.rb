require "spec_helper"

describe "Sequel::Plugins::Bitemporal" do
  before :all do
    DB.create_table! :rooms do
      primary_key :id
    end
    DB.create_table! :room_versions do
      primary_key :id
      foreign_key :master_id, :rooms
      String      :name
      Fixnum      :price
      Date        :created_at
      Date        :expired_at
      Date        :valid_from
      Date        :valid_to
    end
    @version_class = Class.new Sequel::Model do
      set_dataset :room_versions
      def validate
        super
        errors.add(:name, "is required") unless name
        errors.add(:price, "is required") unless price
      end
    end
    closure = @version_class
    @master_class = Class.new Sequel::Model do
      set_dataset :rooms
      plugin :bitemporal, version_class: closure
    end
  end
  before do
    Timecop.freeze 2009, 11, 28
  end
  after do
    Timecop.return
    @master_class.truncate
    @version_class.truncate
  end
  it "checks version class is given" do
    lambda{
      @version_class.plugin :bitemporal
    }.should raise_error Sequel::Error, "please specify version class to use for bitemporal plugin"
  end
  it "checks required columns are present" do
    lambda{
      @version_class.plugin :bitemporal, :version_class => @master_class
    }.should raise_error Sequel::Error, "bitemporal plugin requires the following missing columns on version class: master_id, valid_from, valid_to, created_at, expired_at"
  end
  it "propagates errors from version to master" do
    master = @master_class.new
    master.should be_valid
    master.attributes = {name: "Single Standard"}
    master.should_not be_valid
    master.errors.should == {price: ["is required"]}
  end
  it "#update_attributes returns false instead of raising errors" do
    master = @master_class.new
    master.update_attributes(name: "Single Standard").should be_false
    master.should be_new
    master.errors.should == {price: ["is required"]}
    master.update_attributes(price: 98).should be_true
  end
  it "allows creating a master and its first version in one step" do
    master = @master_class.new
    master.update_attributes(name: "Single Standard", price: 98).should be_true
    master.should_not be_new
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-28 |          | true    |
    }
  end
  it "prevents creating a new version in the past" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_from: Date.today-1
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-28 |          | true    |
    }
  end
  it "allows creating a new version in the future" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_from: Date.today+1
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-29 |          |         |
    }
  end
  it "doesn't loose previous version in same-day update" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-28 | 2009-11-28 |          |         |
      | Single Standard | 94    | 2009-11-28 |            | 2009-11-28 |          | true    |
    }
  end
  it "allows partial updating based on current version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes price: 94, partial_update: true
    master.update_attributes name: "King Size", partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-28 | 2009-11-28 |          |         |
      | Single Standard | 94    | 2009-11-28 | 2009-11-28 | 2009-11-28 |          |         |
      | King Size       | 94    | 2009-11-28 |            | 2009-11-28 |          | true    |
    }
  end
  it "expires previous version but keep it in history" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Date.today+1
    master.update_attributes price: 94, partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 |            |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94    | 2009-11-29 |            | 2009-11-29 |            | true    |
    }
  end
  it "doesn't expire no longer valid versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Date.today+1
    Timecop.freeze Date.today+1
    master.update_attributes(price: 94, partial_update: true).should be_false
    master.update_attributes name: "Single Standard", price: 94
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94    | 2009-11-29 |            | 2009-11-29 |            | true    |
    }
  end
  it "allows shortening validity (COULD BE IMPROVED!)" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Date.today+1
    master.update_attributes valid_to: Date.today+10, partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 |            |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-29 | 2009-12-09 | true    |
    }
  end
    # Timecop.freeze Date.today+1
    # version.update_attributes valid_to: "2009-12-05"
    # version.master.check_versions %Q{
# | name            | price | created_at | expired_at | valid_from | valid_to   | current |
# | Single Standard | 98.00 | 2009-11-28 | 2009-11-29 | 2009-11-28 |            |         |
# | Single Standard | 98.00 | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
# | Single Standard | 94.00 | 2009-11-29 | 2009-11-30 | 2009-11-29 |            |         |
# | Single Standard | 94.00 | 2009-11-30 |            | 2009-11-29 | 2009-12-05 | true    |
    # }
    # Timecop.freeze Date.today+1
    # version.update_attributes valid_from: "2009-12-02", valid_to: nil, price: 95
    # version.master.check_versions %Q{
# | name            | price | created_at | expired_at | valid_from | valid_to   | current |
# | Single Standard | 98.00 | 2009-11-28 | 2009-11-29 | 2009-11-28 |            |         |
# | Single Standard | 98.00 | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
# | Single Standard | 94.00 | 2009-11-29 | 2009-11-30 | 2009-11-29 |            |         |
# | Single Standard | 94.00 | 2009-11-30 | 2009-12-01 | 2009-11-29 | 2009-12-05 |         |
# | Single Standard | 94.00 | 2009-12-01 |            | 2009-11-29 | 2009-12-02 | true    |
# | Single Standard | 95.00 | 2009-12-01 |            | 2009-11-02 |            |         |
    # }
    # Timecop.freeze Date.today+1
    # version.master.check_versions %Q{
# | name            | price | created_at | expired_at | valid_from | valid_to   | current |
# | Single Standard | 98.00 | 2009-11-28 | 2009-11-29 | 2009-11-28 |            |         |
# | Single Standard | 98.00 | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
# | Single Standard | 94.00 | 2009-11-29 | 2009-11-30 | 2009-11-29 |            |         |
# | Single Standard | 94.00 | 2009-11-30 | 2009-12-01 | 2009-11-29 | 2009-12-05 |         |
# | Single Standard | 94.00 | 2009-12-01 |            | 2009-11-29 | 2009-12-02 |         |
# | Single Standard | 95.00 | 2009-12-01 |            | 2009-11-02 |            | true    |
    # }
    # missing scenarios:
    # - same date update
    # - save unchanged
    # - delete scheduled version
    # - delete all versions
    # - simultaneous updates
end
