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
    assert_equal "10000", result[[ "Summer", "FloatingPointResort", "SingletonRoom" ]]
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

    assert_equal "73000", result[[ "Summer", "FloatingPointResort", "SingletonRoom" ]]
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

  test "connection refused is retried once and raises ConnectionError on the second failure" do
    stub_request(:post, PRICING_URL).to_raise(Errno::ECONNREFUSED)

    assert_raises(PricingClient::ConnectionError) { PricingClient.fetch_all }
    assert_requested(:post, PRICING_URL, times: 2)
  end

  test "connection refused then success retries once and returns the result" do
    stub_request(:post, PRICING_URL)
      .to_raise(Errno::ECONNREFUSED)
      .then.to_return(status: 200, body: { rates: valid_rates_payload }.to_json)

    result = PricingClient.fetch_all

    assert_equal 36, result.size
    assert_requested(:post, PRICING_URL, times: 2)
  end

  test "upstream_calls_today counts every attempt, including retries" do
    stub_request(:post, PRICING_URL)
      .to_return(status: 500, body: { error: "boom" }.to_json)
      .then.to_return(status: 200, body: { rates: valid_rates_payload }.to_json)

    assert_equal 0, PricingClient.upstream_calls_today

    PricingClient.fetch_all

    assert_equal 2, PricingClient.upstream_calls_today
  end

  test "logs a WARN once the daily counter exceeds the threshold" do
    Rails.cache.write(
      PricingClient.upstream_calls_cache_key,
      PricingClient::UPSTREAM_CALLS_WARN_THRESHOLD,
      expires_in: PricingClient::UPSTREAM_CALLS_TTL
    )
    stub_request(:post, PRICING_URL).to_return(status: 200, body: { rates: valid_rates_payload }.to_json)

    logs = capture_structured_logs { PricingClient.fetch_all }

    entry = JSON.parse(logs.lines.find { |l| l.include?('"event":"pricing.upstream_calls_exceeded"') })
    assert_equal "pricing.upstream_calls_exceeded", entry["event"]
    assert_equal PricingClient::UPSTREAM_CALLS_WARN_THRESHOLD + 1, entry["upstream_calls_today"]
    assert_equal PricingClient::UPSTREAM_CALLS_WARN_THRESHOLD, entry["threshold"]
  end

  test "does not log a WARN while at or under the threshold" do
    Rails.cache.write(
      PricingClient.upstream_calls_cache_key,
      PricingClient::UPSTREAM_CALLS_WARN_THRESHOLD - 1,
      expires_in: PricingClient::UPSTREAM_CALLS_TTL
    )
    stub_request(:post, PRICING_URL).to_return(status: 200, body: { rates: valid_rates_payload }.to_json)

    logs = capture_structured_logs { PricingClient.fetch_all }

    assert_nil logs.lines.find { |l| l.include?('"event":"pricing.upstream_calls_exceeded"') }
  end
end
