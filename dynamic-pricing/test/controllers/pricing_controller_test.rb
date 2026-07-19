require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
  RATE_API_PRICING_URL = "#{Rails.application.config.x.rate_api.url}/pricing".freeze

  def valid_rates_payload
    PricingQuery::PERIODS.product(PricingQuery::HOTELS, PricingQuery::ROOMS).map.with_index do |(period, hotel, room), i|
      { "period" => period, "hotel" => hotel, "room" => room, "rate" => (10_000 + i).to_s }
    end
  end

  test "should get pricing with all parameters" do
    stub_request(:post, RATE_API_PRICING_URL).to_return(status: 200, body: { rates: valid_rates_payload }.to_json)

    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :success
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "10000", json_response["rate"]
  end

  test "should return 503 when the rate API fails" do
    stub_request(:post, RATE_API_PRICING_URL).to_return(status: 401, body: { error: "Unauthorized" }.to_json)

    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :service_unavailable
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "temporarily unavailable"
  end

  test "should reject when period is missing" do
    get api_v1_pricing_url, params: { hotel: "FloatingPointResort", room: "SingletonRoom" }

    assert_response :unprocessable_content
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "Missing required parameter: period", json_response["error"]
    assert_not_requested :post, RATE_API_PRICING_URL
  end

  test "should reject when hotel is missing" do
    get api_v1_pricing_url, params: { period: "Summer", room: "SingletonRoom" }

    assert_response :unprocessable_content
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "Missing required parameter: hotel", json_response["error"]
    assert_not_requested :post, RATE_API_PRICING_URL
  end

  test "should reject when room is missing" do
    get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort" }

    assert_response :unprocessable_content
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "Missing required parameter: room", json_response["error"]
    assert_not_requested :post, RATE_API_PRICING_URL
  end

  test "should reject when all parameters are missing" do
    get api_v1_pricing_url

    assert_response :unprocessable_content
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "Missing required parameters: period, hotel, room", json_response["error"]
    assert_not_requested :post, RATE_API_PRICING_URL
  end

  test "should treat blank parameters as missing" do
    get api_v1_pricing_url, params: { period: "", hotel: "", room: "" }

    assert_response :unprocessable_content
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "Missing required parameters: period, hotel, room", json_response["error"]
    assert_not_requested :post, RATE_API_PRICING_URL
  end

  test "should reject invalid period" do
    get api_v1_pricing_url, params: {
      period: "summer-2024",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :unprocessable_content
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "period must be one of: Summer, Autumn, Winter, Spring", json_response["error"]
    assert_not_requested :post, RATE_API_PRICING_URL
  end

  test "should reject invalid hotel" do
    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "InvalidHotel",
      room: "SingletonRoom"
    }

    assert_response :unprocessable_content
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "hotel must be one of: FloatingPointResort, GitawayHotel, RecursionRetreat", json_response["error"]
    assert_not_requested :post, RATE_API_PRICING_URL
  end

  test "should reject invalid room" do
    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "InvalidRoom"
    }

    assert_response :unprocessable_content
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "room must be one of: SingletonRoom, BooleanTwin, RestfulKing", json_response["error"]
    assert_not_requested :post, RATE_API_PRICING_URL
  end
end
