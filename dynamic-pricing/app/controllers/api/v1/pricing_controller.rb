class Api::V1::PricingController < ApplicationController
  before_action :validate_query

  def index
    service = Api::V1::PricingService.new(period: @query.period, hotel: @query.hotel, room: @query.room)
    service.run
    if service.valid?
      render json: { rate: service.result }
    else
      render json: { error: service.errors.join(', ') }, status: :bad_request
    end
  end

  private

  def validate_query
    @query = PricingQuery.new(period: params[:period], hotel: params[:hotel], room: params[:room])

    unless @query.valid?
      render json: { error: @query.errors.first }, status: :unprocessable_content
    end
  end
end
