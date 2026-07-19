class Api::V1::PricingController < ApplicationController
  before_action :validate_query

  def index
    begin
      snapshot = RateRefresher.ensure_fresh!
    rescue RateRefresher::Error => e
      return render json: { error: "Pricing data is temporarily unavailable: #{e.message}" }, status: :service_unavailable
    end

    render json: { rate: snapshot.rate_for(period: @query.period, hotel: @query.hotel, room: @query.room) }
  end

  private

  def validate_query
    @query = PricingQuery.new(period: params[:period], hotel: params[:hotel], room: params[:room])

    unless @query.valid?
      render json: { error: @query.errors.first }, status: :unprocessable_content
    end
  end
end
