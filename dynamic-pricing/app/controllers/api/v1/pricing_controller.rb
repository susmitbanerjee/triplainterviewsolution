class Api::V1::PricingController < ApplicationController
  before_action :validate_query

  def index
    started_at = monotonic_now
    previous_snapshot = RateSnapshot.read

    begin
      snapshot = RateRefresher.ensure_fresh!
    rescue RateRefresher::Error => e
      render json: { error: "Pricing data is temporarily unavailable: #{e.message}" }, status: :service_unavailable
      log_request(cache: "unavailable", started_at:)
      return
    end

    cache_status = previous_snapshot&.fetched_at == snapshot.fetched_at ? "hit" : "refreshed"
    render json: {
      rate: snapshot.rate_for(period: @query.period, hotel: @query.hotel, room: @query.room),
      fetched_at: snapshot.fetched_at.iso8601
    }
    log_request(cache: cache_status, started_at:)
  end

  private

  def validate_query
    @query = PricingQuery.new(period: params[:period], hotel: params[:hotel], room: params[:room])

    unless @query.valid?
      render json: { error: @query.errors.first }, status: :unprocessable_content
    end
  end

  def log_request(cache:, started_at:)
    StructuredLogger.info(
      event: "pricing.request",
      request_id: request.request_id,
      cache: cache,
      status: response.status,
      duration_ms: elapsed_ms(started_at)
    )
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started_at)
    ((monotonic_now - started_at) * 1000).round
  end
end
