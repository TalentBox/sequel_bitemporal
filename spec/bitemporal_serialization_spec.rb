require "spec_helper"
require "json"

RSpec.describe "Sequel::Plugins::Bitemporal", :skip_jdbc_sqlite do
  before :all do
    db_setup
    @version_class.instance_eval do
      plugin :serialization
      serialize_attributes :json, :name
    end
  end
  subject{ @master_class.new.update_attributes name: {test: 1}, price: 18 }
  it "serializes as expected" do
    expect(subject.name).to eq({"test" => 1})
  end
  it "doesn't create a new version when value hasn't changed" do
    name = subject.name.dup
    name["test"] = 1
    subject.attributes = {name: name}
    expect{ subject.save }.not_to change(@version_class, :count)
  end
  it "doesn't create a new version when value is the same" do
    subject.attributes = {name: {"test" => 1}}
    expect{ subject.save }.not_to change(@version_class, :count)
  end
  it "does create a new version when value has changed" do
    name = subject.name.dup
    name["test"] = 0
    subject.attributes = {name: name}
    expect{ subject.save }.to change(@version_class, :count).by 1
  end
  it "does create a new version when value is not the same" do
    subject.attributes = {name: {"test" => 0}}
    expect{ subject.save }.to change(@version_class, :count).by 1
  end
  it "does allow to restore" do
    subject.current_version.destroy
    subject.reload
    expect{ subject.restore }.to change(@version_class, :count).by 1
    expect(subject.name).to eq({"test" => 1})
  end
  it "can propagate changes to future versions per column" do
    propagate_per_column = @master_class.propagate_per_column
    begin
      @master_class.instance_variable_set :@propagate_per_column, true
      master = @master_class.new
      master.update_attributes name: {full_name: "Single Standard"}, price: 12, length: nil, width: 1
      initial_today = Date.today
      Timecop.freeze initial_today+1 do
        master.update_attributes valid_from: initial_today+4, name: {full_name: "King Size"}, price: 15, length: 2, width: 2
        expect(master.propagated_during_last_save.size).to eq(0)
      end
      Timecop.freeze initial_today+2 do
        master.update_attributes valid_from: initial_today+3, length: 1, width: 1
        expect(master.propagated_during_last_save.size).to eq(0)
      end
      Timecop.freeze initial_today+3 do
        master.update_attributes valid_from: initial_today+2, length: 3, width: 4
        expect(master.propagated_during_last_save.size).to eq(1)
      end
      versions = master.versions_dataset.order(:id).all
      expect(versions[0].name).to eq({"full_name" => "Single Standard"})
      expect(versions[1].name).to eq({"full_name" => "Single Standard"})
      expect(versions[2].name).to eq({"full_name" => "King Size"})
      expect(versions[3].name).to eq({"full_name" => "Single Standard"})
      expect(versions[4].name).to eq({"full_name" => "Single Standard"})
      expect(versions[5].name).to eq({"full_name" => "Single Standard"})
      expect(versions[6].name).to eq({"full_name" => "Single Standard"})
      expect(versions[7].name).to eq({"full_name" => "Single Standard"})
    ensure
      @master_class.instance_variable_set :@propagate_per_column, propagate_per_column
    end
  end

  it "can propage changes to future version per column with defaults" do
    propagate_per_column = @master_class.propagate_per_column
    begin
      @master_class.instance_variable_set :@propagate_per_column, true
      @version_class.class_eval do
        define_method :name do
          super() || {}
        end
      end
      master = @master_class.new
      expect( master.name ).to eql({})
      expect( master.save ).to be_truthy
      @version_class.create master_id: master.id, valid_from: Date.parse("2016-01-01"), valid_to: Date.parse("2017-01-01"), price: 0
      @version_class.create master_id: master.id, valid_from: Date.parse("2017-01-01"), valid_to: Date.parse("2018-01-01"), price: 0, length: 10
      @version_class.create master_id: master.id, valid_from: Date.parse("2018-01-01"), valid_to: Date.parse("2019-01-01"), price: 0, length: 20
      @version_class.create master_id: master.id, valid_from: Date.parse("2019-01-01"), valid_to: Date.parse("2020-01-01"), price: 10, length: 20
      expect(
        master.update_attributes valid_from: Date.parse("2016-01-01"), price: 10
      ).to be_truthy
      result = master.versions_dataset.order(:expired_at, :valid_from).all.map do |version|
        [!!version.expired_at, version.valid_from.year, version.valid_to.year, version.price, version.length, version.width, version[:name]]
      end
      expect(result).to eql [
        [false, 2016, 2017, 10, nil, nil, nil],
        [false, 2017, 2018, 0, 10, nil, "{}"],
        [false, 2018, 2019, 0, 20, nil, nil],
        [false, 2019, 2020, 10, 20, nil, nil],
        [true, 2016, 2017, 0, nil, nil, nil],
        [true, 2017, 2018, 0, 10, nil, nil],
      ]
    ensure
      @version_class.class_eval do
        undef_method :name
      end
      @master_class.instance_variable_set :@propagate_per_column, propagate_per_column
    end
  end

end
