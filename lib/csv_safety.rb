module CsvSafety
  FORMULA_PREFIX = /\A[=+\-@\t\r\n＝＋－＠]/.freeze

  def self.cell(value)
    return value unless value.is_a?(String)

    value.match?(FORMULA_PREFIX) ? "'#{value}" : value
  end

  def self.row(values)
    values.map { |value| cell(value) }
  end
end
