require "spec_helper"

RSpec.describe "Sequel::Plugins::Bitemporal", "composite_primary_key" do
  before :all do
    setup_composite_primary_key
  end

  describe "::version_foreign_keys" do
    context "when is invoked without args" do
      it "returns master_id" do
        expect(Sequel::Plugins::Bitemporal.bitemporal_excluded_columns).to(
          eq([:id, :master_id, :valid_from, :valid_to, :created_at, :expired_at])
        )
      end
    end
  end

  describe "missing required foreign keys in version table" do
    ERROR_TEXT = "bitemporal plugin requires the following missing columns on version class: department_id, team_id"

    it "raises error" do
      expect do
        setup_composite_primary_key(with_foreign_key: false)
      end.to raise_error Sequel::Error, ERROR_TEXT
    end
  end

  describe "versions work correctly" do
    let(:master) { @master_class.new(name: "john Smith") }
    let(:junior) { "Junior Ruby-developer" }
    let(:senior) { "Senior Ruby-developer" }
    let(:two_years_in_seconds) { 2 * 365 * 24 * 60 * 60 }

    before do
      setup_composite_primary_key
      master.department_id = 1
      master.team_id = 1
      master.save

      Sequel::Plugins::Bitemporal.at(Time.now) do
        master.update_attributes(position: junior)
      end

      Sequel::Plugins::Bitemporal.at(Time.now + two_years_in_seconds) do
        master.update_attributes(position: senior)
      end
    end

    specify do
      Sequel::Plugins::Bitemporal.at(Time.now) do
        expect(master.reload.position).to eq(junior)
      end

      Sequel::Plugins::Bitemporal.at(Time.now + two_years_in_seconds) do
        expect(master.reload.position).to eq(senior)
      end
    end
  end
end
