require "spec_helper"
require "json"

describe "Sequel::Plugins::Bitemporal" do
  include DbHelpers
  before :all do
    db_setup
    @version_class.instance_eval do
      plugin :serialization
      serialize_attributes :json, :name
    end
  end
  subject{ @master_class.new.update_attributes name: {test: 1}, price: 18 }
  it "serializes as expected" do
    subject.name.should == {"test" => 1}
  end
  it "doesn't create a new version when value hasn't changed" do
    name = subject.name.dup
    name["test"] = 1
    subject.attributes = {name: name}
    lambda{ subject.save }.should_not change(@version_class, :count)
  end
  it "doesn't create a new version when value is the same" do
    subject.attributes = {name: {"test" => 1}}
    lambda{ subject.save }.should_not change(@version_class, :count)
  end
  it "does create a new version when value has changed" do
    name = subject.name.dup
    name["test"] = 0
    subject.attributes = {name: name}
    lambda{ subject.save }.should change(@version_class, :count).by 1
  end
  it "does create a new version when value is not the same" do
    subject.attributes = {name: {"test" => 0}}
    lambda{ subject.save }.should change(@version_class, :count).by 1
  end
  it "does allow to restore" do
    subject.current_version.destroy
    subject.reload
    lambda{ subject.restore }.should change(@version_class, :count).by 1
    subject.name.should == {"test" => 1}
  end
end
