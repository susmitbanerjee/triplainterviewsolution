require "test_helper"

class PricingClientTest < ActiveSupport::TestCase
  PRICING_URL = "#{Rails.application.config.x.rate_api.url}/pricing".freeze
  TOKEN = Rails.application.config.x.rate_api.token

  def valid_rates_payload
    PricingQuery::PERIODS.product(PricingQuery::HOTELS, PricingQuery::ROOMS).map.with_index do |(period, hotel, room), i|
      { "period" => period, "hotel" => hotel, "room" => room, "rate" => (10_000 + i).to_s }
    end
  end

  def expected_request_body
    {
      attributes: PricingQuery::PERIODS.product(PricingQuery::HOTELS, PricingQuery::ROOMS).map do |period, hotel, room|
        { "period" => period, "hotel" => hotel, "room" => room }
      end
    }
  end

  test "happy path returns 36 rates keyed by [period, hotel, room]" do
    stub_request(:post, PRICING_URL).to_return(
      status: 200,
      body: { rates: valid_rates_payload }.to_json
    )

    result = PricingClient.fetch_all

    assert_equal 36, result.size
    assert_equal "10000", result[["Summer", "FloatingPointResort", "SingletonRoom"]]
    assert result.values.all? { |v| v.is_a?(String) }
  end

  test "assert exact request body shape and headers" do
    stub_request(:post, PRICING_URL).to_return(
      status: 200,
      body: { rates: valid_rates_payload }.to_json
    )

    PricingClient.fetch_all

    assert_requested(:post, PRICING_URL, headers: { "Content-Type" => "application/json", "token" => TOKEN }) do |req|
      JSON.parse(req.body) == JSON.parse(expected_request_body.to_json)
    end
  end

  test "accepts integer rate values and normalizes them to strings" do
    payload = valid_rates_payload
    payload.first["rate"] = 73_000

    stub_request(:post, PRICING_URL).to_return(status: 200, body: { rates: payload }.to_json)

    result = PricingClient.fetch_all

    assert_equal "73000", result[["Summer", "FloatingPointResort", "SingletonRoom"]]
  end

  test "timeout then success retries once and returns the result" do
    stub_request(:post, PRICING_URL)
      .to_timeout
      .then.to_return(status: 200, body: { rates: valid_rates_payload }.to_json)

    result = PricingClient.fetch_all

    assert_equal 36, result.size
    assert_requested(:post, PRICING_URL, times: 2)
  end

  test "timeout twice raises PricingClient::Timeout" do
    stub_request(:post, PRICING_URL).to_timeout

    assert_raises(PricingClient::Timeout) { PricingClient.fetch_all }
    assert_requested(:post, PRICING_URL, times: 2)
  end

  test "500 is retried once and succeeds on the second attempt" do
    stub_request(:post, PRICING_URL)
      .to_return(status: 500, body: { error: "boom" }.to_json)
      .then.to_return(status: 200, body: { rates: valid_rates_payload }.to_json)

    result = PricingClient.fetch_all

    assert_equal 36, result.size
    assert_requested(:post, PRICING_URL, times: 2)
  end

  test "500 twice raises PricingClient::UpstreamError" do
    stub_request(:post, PRICING_URL).to_return(status: 500, body: { error: "boom" }.to_json)

    assert_raises(PricingClient::UpstreamError) { PricingClient.fetch_all }
    assert_requested(:post, PRICING_URL, times: 2)
  end

  test "401 is not retried" do
    stub_request(:post, PRICING_URL).to_return(status: 401, body: { error: "Unauthorized" }.to_json)

    assert_raises(PricingClient::UpstreamError) { PricingClient.fetch_all }
    assert_requested(:post, PRICING_URL, times: 1)
  end

  test "422 is not retried" do
    stub_request(:post, PRICING_URL).to_return(status: 422, body: { error: "Invalid attribute" }.to_json)

    assert_raises(PricingClient::UpstreamError) { PricingClient.fetch_all }
    assert_requested(:post, PRICING_URL, times: 1)
  end

  test "429 raises RateLimited without retry" do
    stub_request(:post, PRICING_URL).to_return(status: 429, body: { error: "Rate limit exceeded (1000/day)" }.to_json)

    assert_raises(PricingClient::RateLimited) { PricingClient.fetch_all }
    assert_requested(:post, PRICING_URL, times: 1)
  end

  test "200 with a missing rate value raises InvalidResponse" do
    payload = valid_rates_payload
    payload.first.delete("rate")

    stub_request(:post, PRICING_URL).to_return(status: 200, body: { rates: payload }.to_json)

    assert_raises(PricingClient::InvalidResponse) { PricingClient.fetch_all }
  end

  test "200 with an extra rate entry raises InvalidResponse" do
    payload = valid_rates_payload
    payload << payload.first.dup

    stub_request(:post, PRICING_URL).to_return(status: 200, body: { rates: payload }.to_json)

    assert_raises(PricingClient::InvalidResponse) { PricingClient.fetch_all }
  end

  test "200 with a non-numeric rate raises InvalidResponse" do
    payload = valid_rates_payload
    payload.first["rate"] = "not-a-number"

    stub_request(:post, PRICING_URL).to_return(status: 200, body: { rates: payload }.to_json)

    assert_raises(PricingClient::InvalidResponse) { PricingClient.fetch_all }
  end

  test "200 with malformed JSON raises InvalidResponse" do
    stub_request(:post, PRICING_URL).to_return(status: 200, body: "{not valid json")

    assert_raises(PricingClient::InvalidResponse) { PricingClient.fetch_all }
  end

  test "200 with a rates array of the wrong size raises InvalidResponse" do
    payload = valid_rates_payload[0..-2]

    stub_request(:post, PRICING_URL).to_return(status: 200, body: { rates: payload }.to_json)

    assert_raises(PricingClient::InvalidResponse) { PricingClient.fetch_all }
  end
end
