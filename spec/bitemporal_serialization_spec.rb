require "spec_helper"
require "json"

describe "Sequel::Plugins::Bitemporal", :skip_jdbc_sqlite do
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
end
