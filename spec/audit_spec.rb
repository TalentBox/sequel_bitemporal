require "spec_helper"

describe "Sequel::Plugins::Bitemporal" do
  before :all do
    db_setup use_time: false, use_audit_tables: true
  end
  before do
    Timecop.freeze 2009, 12, 1
  end
  after do
    Timecop.return
  end
  let(:author_1){ mock :author, audit_kind: "user", id: 1234 }
  let(:author_2){ mock :author, audit_kind: "user", id: 5678 }
  let(:master){ @master_class.new }

  describe "with sequel-audit_by_day plugin" do

    it "records an audit per master version" do
      master.update_attributes name: "Single Standard", price: 98, updated_by: author_1
      Timecop.freeze Date.today + 5 do
        master.update_attributes name: "King Size", price: 95, updated_by: author_2
      end
      Timecop.freeze Date.today + 2 do
        master.update_attributes name: "Twin", price: 93, updated_by: author_1
      end
      audits = master.audits
      audits.should have(3).items
      audits[0].should have_versions %Q{
        | name_u_user_id | name_at    | price_u_user_id | price_at   | created_at | expired_at | valid_from | valid_to |
        | 1234           | 2009-12-01 | 1234            | 2009-12-01 | 2009-12-01 |            | MIN DATE   | MAX DATE |
      }
      audits[1].should have_versions %Q{
        | name_u_user_id | name_at    | price_u_user_id | price_at   | created_at | expired_at | valid_from | valid_to |
        | 5678           | 2009-12-06 | 5678            | 2009-12-06 | 2009-12-06 |            | MIN DATE   | MAX DATE |
      }
      audits[2].should have_versions %Q{
        | name_u_user_id | name_at    | price_u_user_id | price_at   | created_at | expired_at | valid_from | valid_to |
        | 1234           | 2009-12-03 | 1234            | 2009-12-03 | 2009-12-03 |            | MIN DATE   | MAX DATE |
      }
    end

    it "records changes only" do
      master.update_attributes name: "Single Standard", price: 98, updated_by: author_1
      Timecop.freeze Date.today + 2 do
        master.update_attributes price: 95, updated_by: author_2
      end
      audits = master.audits
      audits.should have(2).items
      audits[0].should have_versions %Q{
        | name_u_user_id | name_at    | price_u_user_id | price_at   | created_at | expired_at | valid_from | valid_to |
        | 1234           | 2009-12-01 | 1234            | 2009-12-01 | 2009-12-01 |            | MIN DATE   | MAX DATE |
      }
      audits[1].should have_versions %Q{
        | name_u_user_id | name_at | price_u_user_id | price_at   | created_at | expired_at | valid_from | valid_to |
        |                |         | 5678            | 2009-12-03 | 2009-12-03 |            | MIN DATE   | MAX DATE |
      }
    end

    it "records changes on the same day as versions" do
      master.update_attributes name: "Single Standard", price: 98, updated_by: author_1
      master.update_attributes name: "King Size", price: 95, updated_by: author_2
      audits = master.audits
      audits.should have(1).item
      audits[0].should have_versions %Q{
        | name_u_user_id | name_at    | price_u_user_id | price_at   | created_at | expired_at | valid_from | valid_to |
        | 1234           | 2009-12-01 | 1234            | 2009-12-01 | 2009-12-01 | 2009-12-01 | MIN DATE   | MAX DATE |
        | 5678           | 2009-12-01 | 5678            | 2009-12-01 | 2009-12-01 |            | MIN DATE   | MAX DATE |
      }
    end

    it "records accumulative changes on the same day" do
      master.update_attributes name: "Single Standard", price: 98, updated_by: author_1
      master.update_attributes price: 95, updated_by: author_2
      audits = master.audits
      audits.should have(1).item
      audits[0].should have_versions %Q{
        | name_u_user_id | name_at    | price_u_user_id | price_at   | created_at | expired_at | valid_from | valid_to |
        | 1234           | 2009-12-01 | 1234            | 2009-12-01 | 2009-12-01 | 2009-12-01 | MIN DATE   | MAX DATE |
        | 1234           | 2009-12-01 | 5678            | 2009-12-01 | 2009-12-01 |            | MIN DATE   | MAX DATE |
      }
    end

  end
end
