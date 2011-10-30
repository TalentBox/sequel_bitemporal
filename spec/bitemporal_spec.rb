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
    @master_class = Class.new Sequel::Model do
      set_dataset :rooms
    end
    closure = @master_class
    @version_class = Class.new Sequel::Model do
      set_dataset :room_versions
      plugin :bitemporal, master: closure
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
  it "checks master class is given" do
    lambda{
      @master_class.plugin :bitemporal
    }.should raise_error ArgumentError, "please specify master class to use for bitemporality"
  end
  it "checks required columns are present" do
    lambda{
      @master_class.plugin :bitemporal, :master => @version_class
    }.should raise_error "bitemporal plugin requires the following missing columns: master_id, valid_from, valid_to, created_at, expired_at"
  end
  it "validates presence of valid_from" do
    version = @version_class.new
    version.should_not be_valid
    version.should have(1).errors
    version.errors[:valid_from].should =~ ["is required"]
  end
  it "sets created_at on create" do
    version = @version_class.new valid_from: Date.today
    version.save.should be_true
    version.created_at.should == Date.today
  end
  it "creates a master if none provided" do
    version = @version_class.new valid_from: Date.today
    version.save.should be_true
    version.master.should be_kind_of(@master_class)
    version.master.should_not be_new
  end
  it "fails validation if unsaved master is not valid" do
    version = @version_class.new valid_from: Date.today
    version.master.should_receive(:valid?).and_return false
    version.should_not be_valid
    version.should have(1).errors
    version.errors[:master].should =~ ["is not valid"]
  end
  it "expires current version on update" do
    version = @version_class.new name: "Single Standard", price: 98, valid_from: Date.today
    version.save
    Timecop.freeze Date.today+1
    version.update price: 94
    version.master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98.00 | 2009-11-28 | 2009-11-29 | 2009-11-28 |            |         |
      | Single Standard | 98.00 | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94.00 | 2009-11-29 |            | 2009-11-29 |            | true    |
    }
    Timecop.freeze Date.today+1
    version.update_attributes valid_to: "2009-12-05"
    version.master.check_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98.00 | 2009-11-28 | 2009-11-29 | 2009-11-28 |            |         |
      | Single Standard | 98.00 | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94.00 | 2009-11-29 | 2009-11-30 | 2009-11-29 |            |         |
      | Single Standard | 94.00 | 2009-11-30 |            | 2009-11-29 | 2009-12-05 | true    |
    }
    Timecop.freeze Date.today+1
    version.update_attributes valid_from: "2009-12-02", valid_to: nil, price: 95
    version.master.check_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98.00 | 2009-11-28 | 2009-11-29 | 2009-11-28 |            |         |
      | Single Standard | 98.00 | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94.00 | 2009-11-29 | 2009-11-30 | 2009-11-29 |            |         |
      | Single Standard | 94.00 | 2009-11-30 | 2009-12-01 | 2009-11-29 | 2009-12-05 |         |
      | Single Standard | 94.00 | 2009-12-01 |            | 2009-11-29 | 2009-12-02 | true    |
      | Single Standard | 95.00 | 2009-12-01 |            | 2009-11-02 |            |         |
    }
    Timecop.freeze Date.today+1
    version.master.check_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98.00 | 2009-11-28 | 2009-11-29 | 2009-11-28 |            |         |
      | Single Standard | 98.00 | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94.00 | 2009-11-29 | 2009-11-30 | 2009-11-29 |            |         |
      | Single Standard | 94.00 | 2009-11-30 | 2009-12-01 | 2009-11-29 | 2009-12-05 |         |
      | Single Standard | 94.00 | 2009-12-01 |            | 2009-11-29 | 2009-12-02 |         |
      | Single Standard | 95.00 | 2009-12-01 |            | 2009-11-02 |            | true    |
    }
    # missing scenarios: delete scheduled version, delete all versions
  end
end