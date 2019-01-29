require "spec_helper"

RSpec.describe "Sequel::Plugins::Bitemporal" do
  let(:hour){ 3600 }
  before :all do
    db_setup use_time: true
  end
  before do
    Timecop.freeze 2009, 11, 28, 10
  end
  after do
    Timecop.return
  end
  it "checks version class is given" do
    expect{
      @version_class.plugin :bitemporal
    }.to raise_error Sequel::Error, "please specify version class to use for bitemporal plugin"
  end
  it "checks required columns are present" do
    expect{
      @version_class.plugin :bitemporal, :version_class => @master_class
    }.to raise_error Sequel::Error, "bitemporal plugin requires the following missing columns on version class: master_id, valid_from, valid_to, created_at, expired_at"
  end
  it "propagates errors from version to master" do
    master = @master_class.new
    expect(master).to be_valid
    master.attributes = {name: "Single Standard"}
    expect(master).not_to be_valid
    expect(master.errors).to eq({price: ["is required"]})
  end
  it "#update_attributes returns false instead of raising errors" do
    master = @master_class.new
    expect(master.update_attributes(name: "Single Standard")).to be_falsey
    expect(master).to be_new
    expect(master.errors).to eq({price: ["is required"]})
    expect(master.update_attributes(price: 98)).to be_truthy
  end
  it "allows creating a master and its first version in one step" do
    master = @master_class.new
    expect(master.update_attributes(name: "Single Standard", price: 98)).to be_truthy
    expect(master).not_to be_new
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at | valid_from                | valid_to | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 |            | 2009-11-28 10:00:00 +0000 | MAX TIME | true    |
    }
  end
  it "allows creating a new version in the past" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_from: Time.now-hour
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at | valid_from                | valid_to | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 |            | 2009-11-28 09:00:00 +0000 | MAX TIME | true    |
    }
  end
  it "allows creating a new version in the future" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_from: Time.now+hour
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at | valid_from                | valid_to | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 |            | 2009-11-28 11:00:00 +0000 | MAX TIME |         |
    }
  end
  it "doesn't loose previous version in same-day update" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 10:00:00 +0000 | MAX TIME |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | MAX TIME | true    |
    }
  end
  it "allows partial updating based on current version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes price: 94
    master.update_attributes name: "King Size"
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 10:00:00 +0000 | MAX TIME |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 10:00:00 +0000 | MAX TIME |         |
      | King Size       | 94    | 2009-11-28 10:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | MAX TIME | true    |
    }
  end
  it "expires previous version but keep it in history" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Time.now+hour
    master.update_attributes price: 94
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 |         |
      | Single Standard | 94    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 11:00:00 +0000 | MAX TIME                  | true    |
    }
  end
  it "doesn't expire no longer valid versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Time.now+hour
    Timecop.freeze Time.now+hour
    expect(master.update_attributes(price: 94)).to be_falsey
    master.update_attributes name: "Single Standard", price: 94
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 |            | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 |         |
      | Single Standard | 94    | 2009-11-28 11:00:00 +0000 |            | 2009-11-28 11:00:00 +0000 | MAX TIME                  | true    |
    }
  end
  it "allows shortening validity (SEE COMMENTS FOR IMPROVEMENTS)" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Time.now+hour
    master.update_attributes valid_to: Time.now+10*hour
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 11:00:00 +0000 | 2009-11-28 21:00:00 +0000 | true    |
    }
    # would be even better if it could be:
    # | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
    # | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | MAX TIME                  |         |
    # | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | 2009-11-28 21:00:00 +0000 | true    |
  end
  it "allows extending validity (SEE COMMENTS FOR IMPROVEMENTS)" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Time.now+2*hour
    Timecop.freeze Time.now+hour
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 |            | 2009-11-28 10:00:00 +0000 | 2009-11-28 12:00:00 +0000 | true    |
    }
    master.update_attributes valid_to: nil
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 12:00:00 +0000 |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 11:00:00 +0000 | MAX TIME                  | true    |
    }
    # would be even better if it could be:
    # | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
    # | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 12:00:00 +0000 |         |
    # | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | MAX TIME                  | true    |
  end
  it "don't create any new version without change " do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes price: 98
    master.update_attributes name: "Single Standard", price: 98
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at | valid_from               | valid_to | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 |            | 2009-11-28 10:00:00 +0000| MAX TIME | true    |
    }
  end
  it "change in validity still creates a new version (SEE COMMENTS FOR IMPROVEMENTS)" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Time.now+hour
    master.update_attributes price: 98, valid_from: Time.now-2*hour
    master.update_attributes price: 98, valid_from: Time.now+1*hour
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 |            | 2009-11-28 10:00:00 +0000 | MAX TIME                  | true    |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |            | 2009-11-28 09:00:00 +0000 | 2009-11-28 10:00:00 +0000 |         |
    }
    # would be even better if it could be:
    # | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
    # | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | MAX TIME                  |         |
    # | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 09:00:00 +0000 | MAX TIME                  | true    |
  end
  it "overrides no future versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Time.now+2*hour
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour, valid_to: Time.now+4*hour
    master.update_attributes name: "Single Standard", price: 95, valid_from: Time.now+4*hour, valid_to: Time.now+6*hour
    Timecop.freeze Time.now+hour
    master.update_attributes name: "King Size", valid_to: nil
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 12:00:00 +0000 |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0000 |                           | 2009-11-28 12:00:00 +0000 | 2009-11-28 14:00:00 +0000 |         |
      | Single Standard | 95    | 2009-11-28 10:00:00 +0000 |                           | 2009-11-28 14:00:00 +0000 | 2009-11-28 16:00:00 +0000 |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 |         |
      | King Size       | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 11:00:00 +0000 | 2009-11-28 12:00:00 +0000 | true    |
    }
  end
  it "overrides multiple future versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Time.now+2*hour
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour, valid_to: Time.now+4*hour
    master.update_attributes name: "Single Standard", price: 95, valid_from: Time.now+4*hour, valid_to: Time.now+6*hour
    Timecop.freeze Time.now+hour
    master.update_attributes name: "King Size", valid_to: Time.now+4*hour
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 12:00:00 +0000 |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 12:00:00 +0000 | 2009-11-28 14:00:00 +0000 |         |
      | Single Standard | 95    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 14:00:00 +0000 | 2009-11-28 16:00:00 +0000 |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 |         |
      | Single Standard | 95    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 15:00:00 +0000 | 2009-11-28 16:00:00 +0000 |         |
      | King Size       | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 11:00:00 +0000 | 2009-11-28 15:00:00 +0000 | true    |
    }
  end
  it "overrides all future versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98, valid_to: Time.now+2*hour
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour, valid_to: Time.now+4*hour
    master.update_attributes name: "Single Standard", price: 95, valid_from: Time.now+4*hour, valid_to: Time.now+6*hour
    Timecop.freeze Time.now+hour
    master.update_attributes name: "King Size", valid_to: Time.utc(9999)
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 12:00:00 +0000 |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 12:00:00 +0000 | 2009-11-28 14:00:00 +0000 |         |
      | Single Standard | 95    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 14:00:00 +0000 | 2009-11-28 16:00:00 +0000 |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 |         |
      | King Size       | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 11:00:00 +0000 | MAX TIME                  | true    |
    }
  end
  it "allows deleting current version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    Timecop.freeze Time.now+hour
    expect(master.current_version.destroy).to be_truthy
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 10:00:00 +0000 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 12:00:00 +0000 |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0000 |                           | 2009-11-28 12:00:00 +0000 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 |         |
    }
  end
  it "allows deleting a future version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    Timecop.freeze Time.now+hour
    expect(master.versions.last.destroy).to be_truthy
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 10:00:00 +0000 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 12:00:00 +0000 |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 12:00:00 +0000 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | MAX TIME                  | true    |
    }
  end
  it "allows deleting all versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    Timecop.freeze Time.now+hour
    expect(master.destroy).to be_truthy
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 10:00:00 +0000 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | 2009-11-28 12:00:00 +0000 |         |
      | Single Standard | 94    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 12:00:00 +0000 | MAX TIME                  |         |
    }
  end
  it "allows simultaneous updates without information loss" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Time.now+hour
    master2 = @master_class.find id: master.id
    master.update_attributes name: "Single Standard", price: 94
    master2.update_attributes name: "Single Standard", price: 95
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 |         |
      | Single Standard | 94    | 2009-11-28 11:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 11:00:00 +0000 | MAX TIME                  |         |
      | Single Standard | 95    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 11:00:00 +0000 | MAX TIME                  | true    |
    }
  end
  it "allows simultaneous cumulative updates" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Time.now+hour
    master2 = @master_class.find id: master.id
    master.update_attributes price: 94
    master2.update_attributes name: "King Size"
    expect(master).to have_versions %Q{
      | name            | price | created_at                | expired_at                | valid_from                | valid_to                  | current |
      | Single Standard | 98    | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 10:00:00 +0000 | MAX TIME                  |         |
      | Single Standard | 98    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 10:00:00 +0000 | 2009-11-28 11:00:00 +0000 |         |
      | Single Standard | 94    | 2009-11-28 11:00:00 +0000 | 2009-11-28 11:00:00 +0000 | 2009-11-28 11:00:00 +0000 | MAX TIME                  |         |
      | King Size       | 94    | 2009-11-28 11:00:00 +0000 |                           | 2009-11-28 11:00:00 +0000 | MAX TIME                  | true    |
    }
  end
  it "allows eager loading with conditions on current version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    expect(@master_class.eager_graph(:current_version).where(Sequel.lit("rooms_current_version.id IS NOT NULL")).first).to be
    Timecop.freeze Time.now+hour
    master.destroy
    expect(@master_class.eager_graph(:current_version).where(Sequel.lit("rooms_current_version.id IS NOT NULL")).first).to be_nil
  end
  it "allows loading masters with a current version" do
    master_destroyed = @master_class.new
    master_destroyed.update_attributes name: "Single Standard", price: 98
    master_destroyed.destroy
    master_with_current = @master_class.new
    master_with_current.update_attributes name: "Single Standard", price: 94
    master_with_future = @master_class.new
    master_with_future.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    expect(@master_class.with_current_version.all.size).to eq(1)
  end
  it "gets pending or current version attributes" do
    master = @master_class.new
    expect(master.attributes).to eq({})
    expect(master.pending_version).to be_nil
    expect(master.current_version).to be_nil
    expect(master.pending_or_current_version.name).to be_nil
    expect(master.name).to be_nil

    master.update_attributes name: "Single Standard", price: 98
    expect(master.attributes[:name]).to eq("Single Standard")
    expect(master.pending_version).to be_nil
    expect(master.pending_or_current_version.name).to eq("Single Standard")
    expect(master.name).to eq("Single Standard")

    master.attributes = {name: "King Size"}
    expect(master.attributes[:name]).to eq("King Size")
    expect(master.pending_version).to be
    expect(master.pending_or_current_version.name).to eq("King Size")
    expect(master.name).to eq("King Size")
  end
  it "allows to go back in time" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Time.now+1*hour
    master.update_attributes price: 94
    expect(master.current_version.price).to eq(94)
    Sequel::Plugins::Bitemporal.as_we_knew_it(Time.now-1*hour) do
      expect(master.current_version(:reload => true).price).to eq(98)
    end
  end
  it "correctly reset time if failure when going back in time" do
    before = Sequel::Plugins::Bitemporal.now
    expect do
      Sequel::Plugins::Bitemporal.at(Time.now+1*hour) do
        raise StandardError, "error during back in time"
      end
    end.to raise_error StandardError
    expect(Sequel::Plugins::Bitemporal.now).to eq(before)
    expect do
      Sequel::Plugins::Bitemporal.as_we_knew_it(Time.now-1*hour) do
        raise StandardError, "error during back in time"
      end
    end.to raise_error StandardError
    expect(Sequel::Plugins::Bitemporal.now).to eq(before)
  end
  it "allows eager loading with conditions on current or future versions" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Time.now+1*hour
    master.update_attributes name: "Single Standard", price: 99
    master.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    res = @master_class.eager_graph(:current_or_future_versions).where(Sequel.negate(Sequel.qualify(:current_or_future_versions, :id) => nil) & {price: 99}).all.first
    expect(res).to be
    expect(res.current_or_future_versions.size).to eq(1)
    expect(res.current_or_future_versions.first.price).to eq(99)
    res = @master_class.eager_graph(:current_or_future_versions).where(Sequel.negate(Sequel.qualify(:current_or_future_versions, :id) => nil) & {price: 94}).all.first
    expect(res).to be
    expect(res.current_or_future_versions.size).to eq(1)
    expect(res.current_or_future_versions.first.price).to eq(94)
    Timecop.freeze Time.now+1*hour
    master.destroy
    expect(@master_class.eager_graph(:current_or_future_versions).where(Sequel.negate(Sequel.qualify(:current_or_future_versions, :id) => nil)).all).to be_empty
  end
  it "allows loading masters with current or future versions" do
    master_destroyed = @master_class.new
    master_destroyed.update_attributes name: "Single Standard", price: 98
    master_destroyed.destroy
    master_with_current = @master_class.new
    master_with_current.update_attributes name: "Single Standard", price: 94
    master_with_future = @master_class.new
    master_with_future.update_attributes name: "Single Standard", price: 94, valid_from: Time.now+2*hour
    expect(@master_class.with_current_or_future_versions.all.size).to eq(2)
  end
end
RSpec.describe "Sequel::Plugins::Bitemporal", "with audit" do
  before :all do
    @audit_class = Class.new
    db_setup use_time: true, audit_class: @audit_class
  end
  before do
    Timecop.freeze 2009, 11, 28, 10
  end
  after do
    Timecop.return
  end
  let(:author){ double :author, audit_kind: "user" }
  it "generates a new audit on creation" do
    master = @master_class.new
    expect(master).to receive(:updated_by).and_return author
    expect(@audit_class).to receive(:audit).with(
      master,
      {},
      hash_including({name: "Single Standard", price: 98}),
      Time.now,
      author
    )
    master.update_attributes name: "Single Standard", price: 98
  end
  it "generates a new audit on full update" do
    master = @master_class.new
    expect(master).to receive(:updated_by).twice.and_return author
    allow(@audit_class).to receive(:audit)
    master.update_attributes name: "Single Standard", price: 98
    expect(@audit_class).to receive(:audit).with(
      master,
      hash_including({name: "Single Standard", price: 98}),
      hash_including({name: "King size", price: 98}),
      Time.now,
      author
    )
    master.update_attributes name: "King size", price: 98
  end
  it "generates a new audit on partial update" do
    master = @master_class.new
    expect(master).to receive(:updated_by).twice.and_return author
    allow(@audit_class).to receive(:audit)
    master.update_attributes name: "Single Standard", price: 98
    expect(@audit_class).to receive(:audit).with(
      master,
      hash_including({name: "Single Standard", price: 98}),
      hash_including({name: "King size", price: 98}),
      Time.now,
      author
    )
    master.update_attributes name: "King size", price: 98
  end
end

RSpec.describe "Sequel::Plugins::Bitemporal", "with audit, specifying how to get the author" do
  before :all do
    @audit_class = Class.new
    db_setup use_time: true, audit_class: @audit_class, audit_updated_by_method: :author
  end
  before do
    Timecop.freeze 2009, 11, 28, 10
  end
  after do
    Timecop.return
  end
  let(:author){ double :author, audit_kind: "user" }
  it "generates a new audit on creation" do
    master = @master_class.new
    expect(master).to receive(:author).and_return author
    expect(@audit_class).to receive(:audit).with(
      master,
      {},
      hash_including({name: "Single Standard", price: 98}),
      Time.now,
      author
    )
    master.update_attributes name: "Single Standard", price: 98
  end
  it "generates a new audit on update" do
    master = @master_class.new
    expect(master).to receive(:author).twice.and_return author
    allow(@audit_class).to receive(:audit)
    master.update_attributes name: "Single Standard", price: 98
    expect(@audit_class).to receive(:audit).with(
      master,
      hash_including({name: "Single Standard", price: 98}),
      hash_including({name: "King size", price: 98}),
      Time.now,
      author
    )
    master.update_attributes name: "King size", price: 98
  end
end

