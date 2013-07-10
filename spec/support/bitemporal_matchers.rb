RSpec::Matchers.define :have_versions do |versions_str|
  @table = have_versions_parse_table versions_str
  @last_index = nil
  @last_version = nil
  match do |master|
    versions = master.versions_dataset.order(:id).all
    columns = @table.first.keys.collect &:to_sym
    versions.size == @table.size && @table.each.with_index.all? do |version, index|
      @last_index = index
      @last_version = version
      master_version = versions[index]
      columns.all? do |column|
        if column==:current
          found = master_version.current?
          expected = (version[column.to_s]=="true").to_s
        else
          found = master_version.send column
          expected = version[column.to_s]
          case expected
          when "MAX DATE"
            expected = "9999-01-01"
          when "MAX TIME"
            expected = "9999-01-01 00:00:00 +0000"
          end
        end
        equal = found.to_s == expected
        puts "#{column}: #{found} != #{expected}" unless equal
        equal
      end
    end
  end
  failure_message_for_should do |master|
    versions = master.versions_dataset.order(:id).all
    if versions.size != @table.size
      "Expected #{master.class} to have #{@table.size} versions but found #{versions.size}"
    else
      "Expected row #{@last_index+1} to match #{@last_version.inspect} but found #{versions[@last_index].inspect}"
    end
  end
end

def have_versions_parse_table(str)
  rows = str.strip.split("\n")
  rows.collect!{|row| row[/^\s*\|(.+)\|\s*$/, 1].split("|").collect(&:strip)}
  headers = rows.shift
  rows.collect{|row| Hash[headers.zip row]}
end
