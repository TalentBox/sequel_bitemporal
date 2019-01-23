require "spec_helper"

describe "composite_primary_key" do
  before :all do
    setup_composite_primary_key
  end

  describe "missing required foreign keys in version table" do
    ERROR_TEXT = "bitemporal plugin requires the following missing columns on version class: department_id, team_id"

    it "raises error" do
      expect do
        setup_composite_primary_key(with_foreign_key: false)
      end.to raise_error Sequel::Error, ERROR_TEXT
    end
  end
end
