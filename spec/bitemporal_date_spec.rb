require "spec_helper"

describe "Sequel::Plugins::Bitemporal" do
  before :all do
    db_setup
  end
  before do
    Timecop.freeze 2009, 11, 28
  end
  after do
    Timecop.return
  end
  it "checks version class is given" do
    lambda{
      @version_class.plugin :bitemporal
    }.should raise_error Sequel::Error, "please specify version class to use for bitemporal plugin"
  end
  it "checks required columns are present" do
    lambda{
      @version_class.plugin :bitemporal, version_class: @master_class
    }.should raise_error Sequel::Error, "bitemporal plugin requires the following missing columns on version class: master_id, valid_from, valid_to, created_at, expired_at"
  end
  it "defines current_versions_dataset" do
    @master_class.new.
      update_attributes(name: "Single Standard", price: 98).
      update_attributes(name: "King Size")
    versions = @master_class.current_versions_dataset.all
    versions.should have(1).version
    versions[0].name.should == "King Size"
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
    result = master.update_attributes name: "Single Standard", price: 98
    result.should be_true
    result.should == master
    master.should_not be_new
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-28 | MAX DATE | true    |
    }
  end
  it "allows creating a new version in the past" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_from: Date.today-1
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-27 | MAX DATE | true    |
    }
  end
  it "allows creating a new version in the future" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_from: Date.today+1
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-29 | MAX DATE |         |
    }
  end
  it "doesn't loose previous version in same-day update" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-28 | 2009-11-28 | MAX DATE |         |
      | Single Standard | 94    | 2009-11-28 |            | 2009-11-28 | MAX DATE | true    |
    }
  end
  it "allows partial updating based on current version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes price: 94
    master.update_attributes name: "King Size"
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-28 | 2009-11-28 | MAX DATE |         |
      | Single Standard | 94    | 2009-11-28 | 2009-11-28 | 2009-11-28 | MAX DATE |         |
      | King Size       | 94    | 2009-11-28 |            | 2009-11-28 | MAX DATE | true    |
    }
  end
  it "expires previous version but keep it in history" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Date.today+1
    master.update_attributes price: 94
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | MAX DATE   |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94    | 2009-11-29 |            | 2009-11-29 | MAX DATE   | true    |
    }
  end
  it "doesn't expire no longer valid versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Date.today+1
    Timecop.freeze Date.today+1
    master.update_attributes(price: 94).should be_false
    master.update_attributes name: "Single Standard", price: 94
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94    | 2009-11-29 |            | 2009-11-29 | MAX DATE   | true    |
    }
  end
  it "allows shortening validity (SEE COMMENTS FOR IMPROVEMENTS)" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Date.today+1
    master.update_attributes valid_to: Date.today+10
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | MAX DATE   |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-29 | 2009-12-09 | true    |
    }
    # would be even better if it could be:
    # | name            | price | created_at | expired_at | valid_from | valid_to   | current |
    # | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | 2009-11-30 |         |
    # | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | 2009-12-09 | true    |
  end
  it "allows extending validity (SEE COMMENTS FOR IMPROVEMENTS)" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Date.today+2
    Timecop.freeze Date.today+1
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-28 | 2009-11-30 | true    |
    }
    master.update_attributes valid_to: nil
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | 2009-11-30 |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-29 | MAX DATE   | true    |
    }
    # would be even better if it could be:
    # | name            | price | created_at | expired_at | valid_from | valid_to   | current |
    # | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | 2009-11-30 |         |
    # | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | MAX DATE   | true    |
  end
  it "don't create any new version without change" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes price: 98
    master.update_attributes name: "Single Standard", price: 98
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-28 | MAX DATE | true    |
    }
  end
  it "change in validity still creates a new version (SEE COMMENTS FOR IMPROVEMENTS)" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Date.today+1
    master.update_attributes price: 98, valid_from: Date.today-2
    master.update_attributes price: 98, valid_from: Date.today+1
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-28 | MAX DATE   | true    |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-27 | 2009-11-28 |         |
    }
    # would be even better if it could be:
    # | name            | price | created_at | expired_at | valid_from | valid_to   | current |
    # | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | MAX DATE   |         |
    # | Single Standard | 98    | 2009-11-29 |            | 2009-11-27 | MAX DATE   | true    |
  end
  it "overrides no future versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Date.today+2
    master.update_attributes name: "Single Standard", price: 94, valid_from: Date.today+2, valid_to: Date.today+4
    master.update_attributes name: "Single Standard", price: 95, valid_from: Date.today+4, valid_to: Date.today+6
    Timecop.freeze Date.today+1
    master.update_attributes name: "King Size", valid_to: nil
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | 2009-11-30 |         |
      | Single Standard | 94    | 2009-11-28 |            | 2009-11-30 | 2009-12-02 |         |
      | Single Standard | 95    | 2009-11-28 |            | 2009-12-02 | 2009-12-04 |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | King Size       | 98    | 2009-11-29 |            | 2009-11-29 | 2009-11-30 | true    |
    }
  end
  it "overrides multiple future versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Date.today+2
    master.update_attributes name: "Single Standard", price: 94, valid_from: Date.today+2, valid_to: Date.today+4
    master.update_attributes name: "Single Standard", price: 95, valid_from: Date.today+4, valid_to: Date.today+6
    Timecop.freeze Date.today+1
    master.update_attributes name: "King Size", valid_to: Date.today+4
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | 2009-11-30 |         |
      | Single Standard | 94    | 2009-11-28 | 2009-11-29 | 2009-11-30 | 2009-12-02 |         |
      | Single Standard | 95    | 2009-11-28 | 2009-11-29 | 2009-12-02 | 2009-12-04 |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 95    | 2009-11-29 |            | 2009-12-03 | 2009-12-04 |         |
      | King Size       | 98    | 2009-11-29 |            | 2009-11-29 | 2009-12-03 | true    |
    }
  end
  it "overrides all future versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Date.today+2
    master.update_attributes name: "Single Standard", price: 94, valid_from: Date.today+2, valid_to: Date.today+4
    master.update_attributes name: "Single Standard", price: 95, valid_from: Date.today+4, valid_to: Date.today+6
    Timecop.freeze Date.today+1
    master.update_attributes name: "King Size", valid_to: Time.utc(9999)
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | 2009-11-30 |         |
      | Single Standard | 94    | 2009-11-28 | 2009-11-29 | 2009-11-30 | 2009-12-02 |         |
      | Single Standard | 95    | 2009-11-28 | 2009-11-29 | 2009-12-02 | 2009-12-04 |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | King Size       | 98    | 2009-11-29 |            | 2009-11-29 | MAX DATE   | true    |
    }
  end
  it "allows deleting current version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 92, valid_from: Date.today-2, valid_to: Date.today
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Date.today+2
    Timecop.freeze Date.today+1
    master.current_version.destroy.should be_true
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 92    | 2009-11-28 |            | 2009-11-26 | 2009-11-28 |         |
      | Single Standard | 98    | 2009-11-28 | 2009-11-28 | 2009-11-28 | MAX DATE   |         |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | 2009-11-30 |         |
      | Single Standard | 94    | 2009-11-28 |            | 2009-11-30 | MAX DATE   |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
    }
    master.should be_deleted
  end
  it "allows deleting current version to restore the previous one" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 92, valid_from: Date.today-2, valid_to: Date.today
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Date.today+2
    Timecop.freeze Date.today+1
    master.current_version.destroy(expand_previous_version: true).should be_true
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 92    | 2009-11-28 |            | 2009-11-26 | 2009-11-28 |         |
      | Single Standard | 98    | 2009-11-28 | 2009-11-28 | 2009-11-28 | MAX DATE   |         |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | 2009-11-30 |         |
      | Single Standard | 94    | 2009-11-28 |            | 2009-11-30 | MAX DATE   |         |
      | Single Standard | 92    | 2009-11-29 |            | 2009-11-29 | 2009-11-30 | true    |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
    }
  end
  it "allows deleting a future version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Date.today+2
    Timecop.freeze Date.today+1
    master.versions.last.destroy.should be_true
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-28 | 2009-11-28 | MAX DATE   |         |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | 2009-11-30 |         |
      | Single Standard | 94    | 2009-11-28 | 2009-11-29 | 2009-11-30 | MAX DATE   |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | MAX DATE   | true    |
    }
  end
  it "allows deleting a future version without expanding the current one" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Date.today+2
    Timecop.freeze Date.today+1
    master.versions.last.destroy(expand_previous_version: false).should be_true
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-28 | 2009-11-28 | MAX DATE   |         |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-28 | 2009-11-30 | true    |
      | Single Standard | 94    | 2009-11-28 | 2009-11-29 | 2009-11-30 | MAX DATE   |         |
    }
  end
  it "allows deleting all versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Date.today+2
    Timecop.freeze Date.today+1
    master.destroy.should be_true
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-28 | 2009-11-28 | MAX DATE   |         |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | 2009-11-30 |         |
      | Single Standard | 94    | 2009-11-28 | 2009-11-29 | 2009-11-30 | MAX DATE   |         |
    }
  end
  it "allows simultaneous updates without information loss" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Date.today+1
    master2 = @master_class.find id: master.id
    master.update_attributes name: "Single Standard", price: 94
    master2.update_attributes name: "Single Standard", price: 95
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | MAX DATE   |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94    | 2009-11-29 | 2009-11-29 | 2009-11-29 | MAX DATE   |         |
      | Single Standard | 95    | 2009-11-29 |            | 2009-11-29 | MAX DATE   | true    |
    }
  end
  it "allows simultaneous cumulative updates" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Date.today+1
    master2 = @master_class.find id: master.id
    master.update_attributes price: 94
    master2.update_attributes name: "King Size"
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | MAX DATE   |         |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94    | 2009-11-29 | 2009-11-29 | 2009-11-29 | MAX DATE   |         |
      | King Size       | 94    | 2009-11-29 |            | 2009-11-29 | MAX DATE   | true    |
    }
  end
  it "can expire invalid versions" do
    master = @master_class.new.update_attributes name: "Single Standard", price: 98
    master.current_version.price = nil
    master.current_version.should_not be_valid
    master.current_version.save validate: false
    Timecop.freeze Date.today+1
    master.update_attributes price: 94
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard |       | 2009-11-28 | 2009-11-29 | 2009-11-28 | MAX DATE   |         |
      | Single Standard |       | 2009-11-29 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94    | 2009-11-29 |            | 2009-11-29 | MAX DATE   | true    |
    }
  end
  it "can propagate changes to future versions per column" do
    propagate_per_column = @master_class.propagate_per_column
    begin
      @master_class.instance_variable_set :@propagate_per_column, true
      master = @master_class.new
      master.update_attributes name: "Single Standard", price: 12, length: nil, width: 1
      initial_today = Date.today
      Timecop.freeze initial_today+1 do
        master.update_attributes valid_from: initial_today+4, name: "King Size", price: 15, length: 2, width: 2
        master.propagated_during_last_save.should have(0).item
      end
      Timecop.freeze initial_today+2 do
        master.update_attributes valid_from: initial_today+3, length: 1, width: 1
        master.propagated_during_last_save.should have(0).item
      end
      Timecop.freeze initial_today+3 do
        master.update_attributes valid_from: initial_today+2, length: 3, width: 4
        master.propagated_during_last_save.should have(1).item
      end
      master.should have_versions %Q{
        | name            | price | length | width | created_at | expired_at | valid_from | valid_to   | current |
        | Single Standard | 12    |        | 1     | 2009-11-28 | 2009-11-29 | 2009-11-28 | MAX DATE   | true    |
        | Single Standard | 12    |        | 1     | 2009-11-29 | 2009-11-30 | 2009-11-28 | 2009-12-02 |         |
        | King Size       | 15    | 2      | 2     | 2009-11-29 |            | 2009-12-02 | MAX DATE   |         |
        | Single Standard | 12    |        | 1     | 2009-11-30 | 2009-12-01 | 2009-11-28 | 2009-12-01 |         |
        | Single Standard | 12    | 1      | 1     | 2009-11-30 | 2009-12-01 | 2009-12-01 | 2009-12-02 |         |
        | Single Standard | 12    |        | 1     | 2009-12-01 |            | 2009-11-28 | 2009-11-30 |         |
        | Single Standard | 12    | 3      | 4     | 2009-12-01 |            | 2009-11-30 | 2009-12-01 |         |
        | Single Standard | 12    | 3      | 4     | 2009-12-01 |            | 2009-12-01 | 2009-12-02 |         |
      }
    ensure
      @master_class.instance_variable_set :@propagate_per_column, propagate_per_column
    end
  end
  it "allows eager loading with conditions on current version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Date.today+2
    @master_class.eager_graph(:current_version).where("rooms_current_version.id IS NOT NULL").first.should be
    Timecop.freeze Date.today+1
    master.destroy
    @master_class.eager_graph(:current_version).where("rooms_current_version.id IS NOT NULL").first.should be_nil
  end
  it "allows loading masters with a current version" do
    master_destroyed = @master_class.new
    master_destroyed.update_attributes name: "Single Standard", price: 98
    master_destroyed.destroy
    master_with_current = @master_class.new
    master_with_current.update_attributes name: "Single Standard", price: 94
    master_with_future = @master_class.new
    master_with_future.update_attributes name: "Single Standard", price: 94, valid_from: Date.today+2
    @master_class.with_current_version.all.should have(1).item
  end
  it "gets pending or current version attributes" do
    master = @master_class.new
    master.attributes.should == {}
    master.pending_version.should be_nil
    master.current_version.should be_nil
    master.name.should be_nil

    master.pending_or_current_version.name.should be_nil
    master.update_attributes name: "Single Standard", price: 98
    master.attributes[:name].should == "Single Standard"
    master.pending_version.should be_nil
    master.pending_or_current_version.name.should == "Single Standard"
    master.name.should == "Single Standard"

    master.attributes = {name: "King Size"}
    master.attributes[:name].should == "King Size"
    master.pending_version.should be
    master.pending_or_current_version.name.should == "King Size"
    master.name.should == "King Size"
  end
  it "allows creating a new version before all other versions in case of propagation per column" do
    propagate_per_column = @master_class.propagate_per_column
    begin
      @master_class.instance_variable_set :@propagate_per_column, true
      master = @master_class.new
      master.update_attributes name: "Single Standard", price: 98
      Timecop.freeze Date.today - 100 do
        master.update_attributes name: "Single Standard", price: 95
        master.propagated_during_last_save.should have(0).item
      end
      master.should have_versions %Q{
        | name            | price | created_at | expired_at | valid_from | valid_to   | current |
        | Single Standard | 98    | 2009-11-28 |            | 2009-11-28 | MAX DATE   | true    |
        | Single Standard | 95    | 2009-08-20 |            | 2009-08-20 | 2009-11-28 |         |
      }
    ensure
      @master_class.instance_variable_set :@propagate_per_column, propagate_per_column
    end
  end
  it "allows to go back in time" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Date.today+1
    master.update_attributes name: "Single Standard", price: 95, valid_from: Date.today+1, valid_to: Date.today+2
    master.update_attributes name: "Single Standard", price: 93, valid_from: Date.today+2, valid_to: Date.today+3
    master.update_attributes name: "Single Standard", price: 91, valid_from: Date.today+3
    Timecop.freeze Date.today+1
    master.update_attributes price: 94
    master.update_attributes price: 96, valid_from: Date.today+2
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 95    | 2009-11-28 | 2009-11-29 | 2009-11-29 | 2009-11-30 |         |
      | Single Standard | 93    | 2009-11-28 |            | 2009-11-30 | 2009-12-01 |         |
      | Single Standard | 91    | 2009-11-28 | 2009-11-29 | 2009-12-01 | MAX DATE   |         |
      | Single Standard | 94    | 2009-11-29 |            | 2009-11-29 | 2009-11-30 | true    |
      | Single Standard | 96    | 2009-11-29 |            | 2009-12-01 | MAX DATE   |         |
    }
    master.current_version.price.should == 94
    Sequel::Plugins::Bitemporal.at(Date.today-1) do
      master.current_version(true).price.should == 98
    end
    Sequel::Plugins::Bitemporal.at(Date.today+1) do
      master.current_version(true).price.should == 93
    end
    Sequel::Plugins::Bitemporal.at(Date.today+2) do
      master.current_version(true).price.should == 96
    end
    Sequel::Plugins::Bitemporal.as_we_knew_it(Date.today-1) do
      master.current_version(true).price.should == 95
      master.current_version.should be_current
      Sequel::Plugins::Bitemporal.at(Date.today-1) do
        master.current_version(true).price.should == 98
      end
      Sequel::Plugins::Bitemporal.at(Date.today+1) do
        master.current_version(true).price.should == 93
      end
      Sequel::Plugins::Bitemporal.at(Date.today+2) do
        master.current_version(true).price.should == 91
      end
    end
  end
  it "correctly reset time if failure when going back in time" do
    before = Sequel::Plugins::Bitemporal.now
    lambda do
      Sequel::Plugins::Bitemporal.at(Date.today+2) do
        raise StandardError, "error during back in time"
      end
    end.should raise_error StandardError
    Sequel::Plugins::Bitemporal.now.should == before
    lambda do
      Sequel::Plugins::Bitemporal.as_we_knew_it(Date.today+2) do
        raise StandardError, "error during back in time"
      end
    end.should raise_error StandardError
    Sequel::Plugins::Bitemporal.now.should == before
  end
  it "allows eager loading with conditions on current or future versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Date.today+1
    master.update_attributes name: "Single Standard", price: 99
    master.update_attributes name: "Single Standard", price: 94, valid_from: Date.today+2
    res = @master_class.eager_graph(:current_or_future_versions).where(Sequel.negate(current_or_future_versions__id: nil) & {price: 99}).all.first
    res.should be
    res.current_or_future_versions.should have(1).item
    res.current_or_future_versions.first.price.should == 99
    res = @master_class.eager_graph(:current_or_future_versions).where(Sequel.negate(current_or_future_versions__id: nil) & {price: 94}).all.first
    res.should be
    res.current_or_future_versions.should have(1).item
    res.current_or_future_versions.first.price.should == 94
    Timecop.freeze Date.today+1
    master.destroy
    @master_class.eager_graph(:current_or_future_versions).where(Sequel.negate(current_or_future_versions__id: nil)).all.should be_empty
  end
  it "allows loading masters with current or future versions" do
    master_destroyed = @master_class.new
    master_destroyed.update_attributes name: "Single Standard", price: 98
    master_destroyed.destroy
    master_with_current = @master_class.new
    master_with_current.update_attributes name: "Single Standard", price: 94
    master_with_future = @master_class.new
    master_with_future.update_attributes name: "Single Standard", price: 94, valid_from: Date.today+2
    @master_class.with_current_or_future_versions.all.should have(2).item
  end
  it "delegates attributes from master to pending_or_current_version" do
    master = @master_class.new
    master.name.should be_nil
    master.update_attributes name: "Single Standard", price: 98
    master.name.should == "Single Standard"
    master.attributes = {name: "King Size"}
    master.name.should == "King Size"
    master.price.should == 98
  end
  it "avoids delegation with option delegate: false" do
    closure = @version_class
    without_delegation_class = Class.new Sequel::Model do
      set_dataset :rooms
      plugin :bitemporal, version_class: closure, delegate: false
    end
    master = without_delegation_class.new
    master.attributes = {name: "Single Standard", price: 98}
    expect{ master.name }.to raise_error NoMethodError
    expect{ master.price }.to raise_error NoMethodError
  end
  it "avoids delegation of some columns only with option excluded_columns" do
    closure = @version_class
    without_delegation_class = Class.new Sequel::Model do
      set_dataset :rooms
      plugin :bitemporal, version_class: closure, excluded_columns: [:name]
    end
    master = without_delegation_class.new
    master.attributes = {name: "Single Standard", price: 98}
    expect{ master.name }.to raise_error NoMethodError
    master.price.should == 98
  end
  it "avoids delegation of columns which are both in master and version" do
    closure = @version_class
    DB.create_table! :rooms_with_name do
      primary_key :id
      String      :name
    end
    without_delegation_class = Class.new Sequel::Model do
      set_dataset :rooms_with_name
      plugin :bitemporal, version_class: closure
    end
    master = without_delegation_class.new name: "Master Hotel"
    master.attributes = {name: "Single Standard", price: 98}
    master.name.should == "Master Hotel"
    master.price.should == 98
    DB.drop_table :rooms_with_name
  end
  it "get current_version association name from class name" do
    class MyNameVersion < Sequel::Model
      set_dataset :room_versions
    end
    class MyName < Sequel::Model
      set_dataset :rooms
      plugin :bitemporal, version_class: MyNameVersion
    end
    expect do
      MyName.eager_graph(:current_version).where("my_name_current_version.id IS NOT NULL").first
    end.not_to raise_error
    Object.send :remove_const, :MyName
    Object.send :remove_const, :MyNameVersion
  end
  it "can update master and current version at the same time" do
    master = @master_class.new.update_attributes name: "Single Standard", price: 98
    master.disabled = true
    master.update_attributes price: 94
    master.reload.disabled.should be_true
  end
  it "uses current version for partial_update even if valid_from is specified" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_from: Date.today-2, valid_to: Date.today
    master.update_attributes name: "Single Standard", price: 94
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-26 | 2009-11-28 |         |
      | Single Standard | 94    | 2009-11-28 |            | 2009-11-28 | MAX DATE   | true    |
    }
    master.update_attributes name: "King Size", valid_from: Date.today-2
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-28 | 2009-11-26 | 2009-11-28 |         |
      | Single Standard | 94    | 2009-11-28 |            | 2009-11-28 | MAX DATE   | true    |
      | King Size       | 94    | 2009-11-28 |            | 2009-11-26 | 2009-11-28 |         |
    }
  end
  it "as_we_knew_it also allows creating and deleting at that time" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Sequel::Plugins::Bitemporal.as_we_knew_it(Date.today+1) do
      master.update_attributes name: "King Size"
    end
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | MAX DATE   | true    |
      | King Size       | 98    | 2009-11-29 |            | 2009-11-28 | MAX DATE   |         |
    }
    Sequel::Plugins::Bitemporal.as_we_knew_it(Date.today+2) do
      master.current_version(true).destroy
    end
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-28 | MAX DATE   | true    |
      | King Size       | 98    | 2009-11-29 | 2009-11-30 | 2009-11-28 | MAX DATE   |         |
      | King Size       | 98    | 2009-11-30 |            | 2009-11-28 | 2009-11-28 |         |
    }
  end
  it "combines as_we_knew_it and at to set valid_from" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_from: Date.today-2, valid_to: Date.today
    master.update_attributes name: "Single Standard", price: 94
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 |            | 2009-11-26 | 2009-11-28 |         |
      | Single Standard | 94    | 2009-11-28 |            | 2009-11-28 | MAX DATE   | true    |
    }
    Sequel::Plugins::Bitemporal.as_we_knew_it(Date.today+1) do
      Sequel::Plugins::Bitemporal.at(Date.today-1) do
        master.update_attributes name: "King Size"
      end
    end
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | valid_from | valid_to   | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 | 2009-11-26 | 2009-11-28 |         |
      | Single Standard | 94    | 2009-11-28 |            | 2009-11-28 | MAX DATE   | true    |
      | Single Standard | 98    | 2009-11-29 |            | 2009-11-26 | 2009-11-27 |         |
      | King Size       | 98    | 2009-11-29 |            | 2009-11-27 | 2009-11-28 |         |
    }
  end
  context "#deleted?" do
    subject{ @master_class.new }
    it "is false unless persisted" do
      subject.should_not be_deleted
    end
    it "is false when persisted with a current version" do
      subject.update_attributes(name: "Single Standard", price: 94).should_not be_deleted
    end
    it "is true when persisted without a current version" do
      subject.update_attributes(name: "Single Standard", price: 94, valid_from: Date.today+1).should be_deleted
    end
  end
  context "#last_version" do
    subject{ @master_class.new }
    it "is nil unless persisted" do
      subject.last_version.should be_nil
    end
    it "is current version when persisted with a current version" do
      subject.update_attributes name: "Single Standard", price: 94
      subject.last_version.should == subject.current_version
    end
    it "is nil with future version but no current version" do
      subject.update_attributes name: "Single Standard", price: 94, valid_from: Date.today+1
      subject.last_version.should be_nil
    end
    it "is last version with previous version but no current version" do
      subject.update_attributes name: "Single Standard", price: 94, valid_from: Date.today-2, valid_to: Date.today-1
      subject.current_version.should be_nil
      subject.last_version.should == subject.versions.last
    end
  end
  context "#restore" do
    subject{ @master_class.new }
    it "make last version current" do
      subject.update_attributes name: "Single Standard", price: 94, valid_from: Date.today-2, valid_to: Date.today-1
      subject.restore
      subject.current_version.should == subject.last_version
    end
    it "can add additional attributes to apply" do
      subject.update_attributes name: "Single Standard", price: 94, valid_from: Date.today-2, valid_to: Date.today-1
      subject.restore name: "New Standard"
      subject.current_version.name.should == "New Standard"
      subject.current_version.price.should == 94
    end
  end
end

describe "Sequel::Plugins::Bitemporal", "with audit" do
  before :all do
    @audit_class = Class.new do
      def self.audit(*args); end
    end
    db_setup audit_class: @audit_class
  end
  before do
    Timecop.freeze 2009, 11, 28
  end
  after do
    Timecop.return
  end
  let(:author){ double :author, audit_kind: "user" }
  it "generates a new audit on creation" do
    master = @master_class.new
    master.should_receive(:updated_by).and_return author
    @audit_class.should_receive(:audit).with(
      master,
      {},
      hash_including({name: "Single Standard", price: 98}),
      Date.today,
      author
    )
    master.update_attributes name: "Single Standard", price: 98
  end
  it "generates a new audit on full update" do
    master = @master_class.new
    master.should_receive(:updated_by).twice.and_return author
    master.update_attributes name: "Single Standard", price: 98
    @audit_class.should_receive(:audit).with(
      master,
      hash_including({name: "Single Standard", price: 98}),
      hash_including({name: "King size", price: 98}),
      Date.today,
      author
    )
    master.update_attributes name: "King size", price: 98
  end
  it "generates a new audit on partial update" do
    master = @master_class.new
    master.should_receive(:updated_by).twice.and_return author
    master.update_attributes name: "Single Standard", price: 98
    @audit_class.should_receive(:audit).with(
      master,
      hash_including({name: "Single Standard", price: 98}),
      hash_including({name: "King size", price: 98}),
      Date.today,
      author
    )
    master.update_attributes name: "King size", price: 98
  end
  it "generate a new audit for each future version update when propagating changes" do
    propagate_per_column = @master_class.propagate_per_column
    begin
      @master_class.instance_variable_set :@propagate_per_column, true
      master = @master_class.new
      master.should_receive(:updated_by).exactly(8).times.and_return author

      master.update_attributes name: "Single Standard", price: 12, length: nil, width: 1
      initial_today = Date.today
      Timecop.freeze initial_today+1 do
        Sequel::Plugins::Bitemporal.at initial_today+4 do
          master.update_attributes valid_from: initial_today+4, name: "King Size", price: 15, length: 2, width: 2
          master.propagated_during_last_save.should have(0).item
        end
      end
      Timecop.freeze initial_today+2 do
        Sequel::Plugins::Bitemporal.at initial_today+3 do
          master.update_attributes valid_from: initial_today+3, length: 1, width: 1
          master.propagated_during_last_save.should have(0).item
        end
      end
      @audit_class.should_receive(:audit).with(
        master,
        hash_including({name: "Single Standard", price: 12, length: nil, width: 1}),
        hash_including({name: "Single Standard", price: 12, length: 3, width: 4}),
        initial_today+2,
        author
      )
      @audit_class.should_receive(:audit).with(
        master,
        hash_including({name: "Single Standard", price: 12, length: 1, width: 1}),
        hash_including({name: "Single Standard", price: 12, length: 1, width: 4}),
        initial_today+3,
        author
      )
      Timecop.freeze initial_today+3 do
        Sequel::Plugins::Bitemporal.at initial_today+2 do
          master.update_attributes valid_from: initial_today+2, length: 3, width: 4
          master.propagated_during_last_save.should have(1).item
        end
      end
    ensure
      @master_class.instance_variable_set :@propagate_per_column, propagate_per_column
    end
  end
end
describe "Sequel::Plugins::Bitemporal", "with audit, specifying how to get the author" do
  before :all do
    @audit_class = Class.new do
      def self.audit(*args); end
    end
    db_setup audit_class: @audit_class, audit_updated_by_method: :author
  end
  let(:author){ double :author, audit_kind: "user" }
  before do
    Timecop.freeze 2009, 11, 28
  end
  after do
    Timecop.return
  end
  it "generates a new audit on creation" do
    master = @master_class.new
    master.should_receive(:author).and_return author
    @audit_class.should_receive(:audit).with(
      master,
      {},
      hash_including({name: "Single Standard", price: 98}),
      Date.today,
      author
    )
    master.update_attributes name: "Single Standard", price: 98
  end
  it "generates a new audit on update" do
    master = @master_class.new
    master.should_receive(:author).twice.and_return author
    master.update_attributes name: "Single Standard", price: 98
    @audit_class.should_receive(:audit).with(
      master,
      hash_including({name: "Single Standard", price: 98}),
      hash_including({name: "King size", price: 98}),
      Date.today,
      author
    )
    master.update_attributes name: "King size", price: 98
  end
end
