require "test_helper"

# Pins the freshness boundary (RateSnapshot::FRESH_FOR = 5.minutes, <=
# inclusive) as observed through the actual endpoint: a snapshot within the
# window is served straight from cache with zero upstream calls; one second
# past it, the endpoint must trigger exactly one refresh.
class Api::V1::PricingControllerFreshnessTest < ActionDispatch::IntegrationTest
  PRICING_UPSTREAM_URL = "#{Rails.application.config.x.rate_api.url}/pricing".freeze
  VALID_PARAMS = { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }.freeze
  BASE_TIME = Time.zone.parse("2026-01-01 12:00:00")

  def stale_rates(rate)
    PricingQuery::PERIODS.product(PricingQuery::HOTELS, PricingQuery::ROOMS).each_with_object({}) do |(period, hotel, room), h|
      h[[ period, hotel, room ]] = rate
    end
  end

  def valid_rates_payload
    PricingQuery::PERIODS.product(PricingQuery::HOTELS, PricingQuery::ROOMS).map.with_index do |(period, hotel, room), i|
      { "period" => period, "hotel" => hotel, "room" => room, "rate" => (10_000 + i).to_s }
    end
  end

  test "serves the existing rate with no upstream call at 4 minutes 59 seconds old" do
    travel_to(BASE_TIME) { RateSnapshot.write(stale_rates("9999")) }

    travel_to(BASE_TIME + 4.minutes + 59.seconds) do
      get api_v1_pricing_url, params: VALID_PARAMS

      assert_response :success
      json_response = JSON.parse(@response.body)
      assert_equal "9999", json_response["rate"]
    end

    assert_not_requested :post, PRICING_UPSTREAM_URL
  end

  test "serves the existing rate with no upstream call at exactly 5 minutes old (inclusive boundary)" do
    travel_to(BASE_TIME) { RateSnapshot.write(stale_rates("9999")) }

    travel_to(BASE_TIME + 5.minutes) do
      get api_v1_pricing_url, params: VALID_PARAMS

      assert_response :success
      json_response = JSON.parse(@response.body)
      assert_equal "9999", json_response["rate"]
    end

    assert_not_requested :post, PRICING_UPSTREAM_URL
  end

  test "triggers exactly one refresh at 5 minutes 1 second old" do
    travel_to(BASE_TIME) { RateSnapshot.write(stale_rates("9999")) }

    stub_request(:post, PRICING_UPSTREAM_URL).to_return(status: 200, body: { rates: valid_rates_payload }.to_json)

    travel_to(BASE_TIME + 5.minutes + 1.second) do
      get api_v1_pricing_url, params: VALID_PARAMS

      assert_response :success
      json_response = JSON.parse(@response.body)
      assert_equal "10000", json_response["rate"]
    end

    assert_requested :post, PRICING_UPSTREAM_URL, times: 1
  end
end
