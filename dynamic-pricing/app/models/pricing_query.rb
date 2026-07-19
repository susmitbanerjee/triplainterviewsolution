class PricingQuery
  PERIODS = %w[Summer Autumn Winter Spring].freeze
  HOTELS = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
  ROOMS = %w[SingletonRoom BooleanTwin RestfulKing].freeze

  FIELDS = {
    period: PERIODS,
    hotel: HOTELS,
    room: ROOMS
  }.freeze

  attr_reader :period, :hotel, :room

  def initialize(period:, hotel:, room:)
    @period = period
    @hotel = hotel
    @room = room
  end

  def valid?
    errors.empty?
  end

  def errors
    @errors ||= compute_errors
  end

  private

  def compute_errors
    missing_fields = FIELDS.keys.select { |field| public_send(field).blank? }
    return [missing_error(missing_fields)] if missing_fields.any?

    FIELDS.each do |field, allowed_values|
      value = public_send(field)
      return ["#{field} must be one of: #{allowed_values.join(', ')}"] unless allowed_values.include?(value)
    end

    []
  end

  def missing_error(missing_fields)
    if missing_fields.size == 1
      "Missing required parameter: #{missing_fields.first}"
    else
      "Missing required parameters: #{missing_fields.join(', ')}"
    end
  end
end
