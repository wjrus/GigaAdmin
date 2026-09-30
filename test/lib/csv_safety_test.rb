require "test_helper"
require "csv"

class CsvSafetyTest < ActiveSupport::TestCase
  test "escapes spreadsheet formula prefixes" do
    assert_equal "'=cmd", CsvSafety.cell("=cmd")
    assert_equal "'+cmd", CsvSafety.cell("+cmd")
    assert_equal "'-cmd", CsvSafety.cell("-cmd")
    assert_equal "'@cmd", CsvSafety.cell("@cmd")
  end

  test "escapes line feeds and localized formula prefixes while preserving CSV cell boundaries" do
    values = [ "\n=1+1", "\t=1+1", "\r=1+1", "＝1+1", "＋1+1", "－1+1", "＠SUM(1)", "=1+1\",=1+1" ]
    escaped = CsvSafety.row(values)

    values.zip(escaped).each { |original, safe| assert_equal "'#{original}", safe }
    assert_equal escaped, CSV.parse_line(CSV.generate_line(escaped))
  end

  test "leaves non-string values and ordinary strings alone" do
    assert_equal "viewer", CsvSafety.cell("viewer")
    assert_equal 42, CsvSafety.cell(42)
    assert_nil CsvSafety.cell(nil)
  end
end
