require "test_helper"

# The whole point of the single-flight + 5-minute-freshness design is a hard
# structural cap on upstream calls: at most one real fetch per 5-minute
# window, so at most 288/day (24h * 60 / 5). This simulates a full day of
# real traffic against the actual endpoint and checks that cap holds.
class PricingDailyTrafficTest < ActionDispatch::IntegrationTest
  PRICING_UPSTREAM_URL = "#{Rails.application.config.x.rate_api.url}/pricing".freeze
  VALID_PARAMS = { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }.freeze
  WINDOWS_PER_DAY = 288
  REQUESTS_PER_WINDOW = 3

  def valid_rates_payload
    PricingQuery::PERIODS.product(PricingQuery::HOTELS, PricingQuery::ROOMS).map.with_index do |(period, hotel, room), i|
      { "period" => period, "hotel" => hotel, "room" => room, "rate" => (10_000 + i).to_s }
    end
  end

  test "a full simulated day of traffic keeps the upstream-call counter within the 288 worst-case bound" do
    stub_request(:post, PRICING_UPSTREAM_URL).to_return(status: 200, body: { rates: valid_rates_payload }.to_json)

    # Midnight, so all 288 five-minute windows (0 .. 23h55m) stay on this
    # same calendar date and share one counter key.
    base = Time.zone.parse("2026-01-01 00:00:00")

    WINDOWS_PER_DAY.times do |window|
      travel_to(base + (window * 5).minutes) do
        REQUESTS_PER_WINDOW.times { get api_v1_pricing_url, params: VALID_PARAMS }
      end
    end

    actual_calls = travel_to(base) { PricingClient.upstream_calls_today }

    assert_operator actual_calls, :<=, WINDOWS_PER_DAY

    # The counter (what production alerting reads) must agree exactly with
    # what actually hit the wire (what WebMock observed) — not just both
    # happen to be small. Note this legitimately lands at 144, not 288:
    # windows are exactly 5 minutes apart and freshness is <= inclusive, so
    # a fetch at window N is still fresh at window N+1 (exactly 5:00 later)
    # and only goes stale by N+2 — real calls happen every other window.
    assert_requested :post, PRICING_UPSTREAM_URL, times: actual_calls
  end
end
