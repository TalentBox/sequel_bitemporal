require "spec_helper"

describe "Sequel::Plugins::Bitemporal" do
  let(:hour){ 3600 }
  before :all do
    DB.drop_table(:room_versions) if DB.table_exists?(:room_versions)
    DB.drop_table(:rooms) if DB.table_exists?(:rooms)
    DB.create_table! :rooms do
      primary_key :id
    end
    DB.create_table! :room_versions do
      primary_key :id
      foreign_key :master_id, :rooms
      String      :name
      Fixnum      :price
      Time        :created_at
      Time        :expired_at
      Time        :valid_from
      Time        :valid_to
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
    Timecop.freeze 2009, 11, 28, 10
    @version_class.truncate
    @master_class.truncate
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
      | name            | price | created_at                | expired_at | valid_from                | valid_to | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 |            | 2009-11-28 10:00:00 +0100 | MAX TIME | true    |
    }
  end
  it "allows creating a new version in the past" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_from: Time.now-hour
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at | valid_from                | valid_to | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 |            | 2009-11-28 09:00:00 +0100 | MAX TIME | true    |
    }
  end
  it "allows creating a new version in the future" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_from: Time.now+hour
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at | valid_from                | valid_to | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 |            | 2009-11-28 11:00:00 +0100 | MAX TIME |         |
    }
  end
  it "doesn't loose previous version in same-day update" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 10:00:00 +0100 | MAX TIME |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | MAX TIME | true    |
    }
  end
  it "allows partial updating based on current version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes price: 94, partial_update: true
    master.update_attributes name: "King Size", partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 10:00:00 +0100 | MAX TIME |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 10:00:00 +0100 | MAX TIME |         |
      | King Size       | 94    | 2009-11-28 10:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | MAX TIME | true    |
    }
  end
  it "expires previous version but keep it in history" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Time.now+hour
    master.update_attributes price: 94, partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 10:00:00 +0100 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 |         |
      | Single Standard | 94    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 11:00:00 +0100 | MAX TIME                  | true    |
    }
  end
  it "doesn't expire no longer valid versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Time.now+hour
    Timecop.freeze Time.now+hour
    master.update_attributes(price: 94, partial_update: true).should be_false
    master.update_attributes name: "Single Standard", price: 94
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 |            | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 |         |
      | Single Standard | 94    | 2009-11-28 11:00:00 +0100 |            | 2009-11-28 11:00:00 +0100 | MAX TIME                  | true    |
    }
  end
  it "allows shortening validity (SEE COMMENTS FOR IMPROVEMENTS)" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Time.now+hour
    master.update_attributes valid_to: Time.now+10*hour, partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 10:00:00 +0100 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 11:00:00 +0100 | 2009-11-28 21:00:00 +0100 | true    |
    }
    # would be even better if it could be:
    # | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
    # | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 10:00:00 +0100 | MAX TIME                  |         |
    # | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | 2009-11-28 21:00:00 +0100 | true    |
  end
  it "allows extending validity (SEE COMMENTS FOR IMPROVEMENTS)" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Time.now+2*hour
    Timecop.freeze Time.now+hour
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 |            | 2009-11-28 10:00:00 +0100 | 2009-11-28 12:00:00 +0100 | true    |
    }
    master.update_attributes valid_to: nil, partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 12:00:00 +0100 |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 11:00:00 +0100 | MAX TIME                  | true    |
    }
    # would be even better if it could be:
    # | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
    # | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 12:00:00 +0100 |         |
    # | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | MAX TIME                  | true    |
  end
  xit "doesn't do anything if unchanged" do
  end
  it "overrides no future versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Time.now+2*hour
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour, valid_to: Time.now+4*hour
    master.update_attributes name: "Single Standard", price: 95, valid_from: Time.now+4*hour, valid_to: Time.now+6*hour
    Timecop.freeze Time.now+hour
    master.update_attributes name: "King Size", valid_to: nil, partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 12:00:00 +0100 |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0100 |                           | 2009-11-28 12:00:00 +0100 | 2009-11-28 14:00:00 +0100 |         |
      | Single Standard | 95    | 2009-11-28 10:00:00 +0100 |                           | 2009-11-28 14:00:00 +0100 | 2009-11-28 16:00:00 +0100 |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 |         |
      | King Size       | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 11:00:00 +0100 | 2009-11-28 12:00:00 +0100 | true    |
    }
  end
  it "overrides multiple future versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Time.now+2*hour
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour, valid_to: Time.now+4*hour
    master.update_attributes name: "Single Standard", price: 95, valid_from: Time.now+4*hour, valid_to: Time.now+6*hour
    Timecop.freeze Time.now+hour
    master.update_attributes name: "King Size", valid_to: Time.now+4*hour, partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 12:00:00 +0100 |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 12:00:00 +0100 | 2009-11-28 14:00:00 +0100 |         |
      | Single Standard | 95    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 14:00:00 +0100 | 2009-11-28 16:00:00 +0100 |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 |         |
      | Single Standard | 95    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 15:00:00 +0100 | 2009-11-28 16:00:00 +0100 |         |
      | King Size       | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 11:00:00 +0100 | 2009-11-28 15:00:00 +0100 | true    |
    }
  end
  it "overrides all future versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Time.now+2*hour
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour, valid_to: Time.now+4*hour
    master.update_attributes name: "Single Standard", price: 95, valid_from: Time.now+4*hour, valid_to: Time.now+6*hour
    Timecop.freeze Time.now+hour
    master.update_attributes name: "King Size", valid_to: Time.utc(9999), partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 12:00:00 +0100 |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 12:00:00 +0100 | 2009-11-28 14:00:00 +0100 |         |
      | Single Standard | 95    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 14:00:00 +0100 | 2009-11-28 16:00:00 +0100 |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 |         |
      | King Size       | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 11:00:00 +0100 | MAX TIME                  | true    |
    }
  end
  it "allows deleting current version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    Timecop.freeze Time.now+hour
    master.current_version.destroy.should be_true
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 10:00:00 +0100 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 12:00:00 +0100 |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0100 |                           | 2009-11-28 12:00:00 +0100 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 |         |
    }
  end
  it "allows deleting a future version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    Timecop.freeze Time.now+hour
    master.versions.last.destroy.should be_true
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 10:00:00 +0100 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 12:00:00 +0100 |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 12:00:00 +0100 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | MAX TIME                  | true    |
    }
  end
  it "allows deleting all versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    Timecop.freeze Time.now+hour
    master.destroy.should be_true
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 10:00:00 +0100 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 10:00:00 +0100 | 2009-11-28 12:00:00 +0100 |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 12:00:00 +0100 | MAX TIME                  |         |
    }
  end
  it "allows simultaneous updates without information loss" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Time.now+hour
    master2 = @master_class.find id: master.id
    master.update_attributes name: "Single Standard", price: 94
    master2.update_attributes name: "Single Standard", price: 95
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 10:00:00 +0100 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 |         |
      | Single Standard | 94    | 2009-11-28 11:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 11:00:00 +0100 | MAX TIME                  |         |
      | Single Standard | 95    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 11:00:00 +0100 | MAX TIME                  | true    |
    }
  end
  it "allows simultaneous cumulative updates" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Time.now+hour
    master2 = @master_class.find id: master.id
    master.update_attributes price: 94, partial_update: true
    master2.update_attributes name: "King Size", partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 10:00:00 +0100 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 10:00:00 +0100 | 2009-11-28 11:00:00 +0100 |         |
      | Single Standard | 94    | 2009-11-28 11:00:00 +0100 | 2009-11-28 11:00:00 +0100 | 2009-11-28 11:00:00 +0100 | MAX TIME                  |         |
      | King Size       | 94    | 2009-11-28 11:00:00 +0100 |                           | 2009-11-28 11:00:00 +0100 | MAX TIME                  | true    |
    }
  end
  it "allows eager loading with conditions on current version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    @master_class.eager_graph(:current_version).where("current_version.id IS NOT NULL").first.should be
    Timecop.freeze Time.now+hour
    master.destroy
    @master_class.eager_graph(:current_version).where("current_version.id IS NOT NULL").first.should be_nil
  end
  it "allows loading masters with a current version" do
    master_destroyed = @master_class.new
    master_destroyed.update_attributes name: "Single Standard", price: 98
    master_destroyed.destroy
    master_with_current = @master_class.new
    master_with_current.update_attributes name: "Single Standard", price: 94
    master_with_future = @master_class.new
    master_with_future.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    @master_class.with_current_version.all.should have(1).item
  end
  it "gets pending or current version attributes" do
    master = @master_class.new
    master.attributes.should == {}
    master.pending_version.should be_nil
    master.pending_or_current_version.should be_nil
    master.update_attributes name: "Single Standard", price: 98
    master.attributes[:name].should == "Single Standard"
    master.pending_version.should be_nil
    master.pending_or_current_version.name.should == "Single Standard"
    master.attributes = {name: "King Size"}
    master.attributes[:name].should == "King Size"
    master.pending_version.should be
    master.pending_or_current_version.name.should == "King Size"
  end
  it "allows to go back in time" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Time.now+1*hour
    master.update_attributes price: 94, partial_update: true
    master.current_version.price.should == 94
    Sequel::Plugins::Bitemporal.as_we_knew_it(Time.now-1*hour) do
      master.current_version(true).price.should == 98
    end
  end
  it "allows eager loading with conditions on current or future versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Time.now+1*hour
    master.update_attributes name: "Single Standard", price: 99
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    res = @master_class.eager_graph(:current_or_future_versions).where({current_or_future_versions__id: nil}.sql_negate & {price: 99}).all.first
    res.should be
    res.current_or_future_versions.should have(1).item
    res.current_or_future_versions.first.price.should == 99
    res = @master_class.eager_graph(:current_or_future_versions).where({current_or_future_versions__id: nil}.sql_negate & {price: 94}).all.first
    res.should be
    res.current_or_future_versions.should have(1).item
    res.current_or_future_versions.first.price.should == 94
    Timecop.freeze Time.now+1*hour
    master.destroy
    @master_class.eager_graph(:current_or_future_versions).where({current_or_future_versions__id: nil}.sql_negate).all.should be_empty
  end
  it "allows loading masters with current or future versions" do
    master_destroyed = @master_class.new
    master_destroyed.update_attributes name: "Single Standard", price: 98
    master_destroyed.destroy
    master_with_current = @master_class.new
    master_with_current.update_attributes name: "Single Standard", price: 94
    master_with_future = @master_class.new
    master_with_future.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    @master_class.with_current_or_future_versions.all.should have(2).item
  end
end