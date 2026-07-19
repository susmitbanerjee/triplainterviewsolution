require "test_helper"

# Covers the full upstream-failure matrix at the controller level: every
# condition PricingClient can raise for must surface as a 503 with a
# condition-appropriate message, must never mutate a previously stored
# snapshot, and must respect PricingClient's retry policy (one retry for
# timeout/connection/5xx, zero for 4xx and malformed-200 conditions).
class Api::V1::PricingControllerUpstreamFailuresTest < ActionDispatch::IntegrationTest
  PRICING_UPSTREAM_URL = "#{Rails.application.config.x.rate_api.url}/pricing".freeze
  VALID_PARAMS = { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }.freeze

  def valid_rates_payload
    PricingQuery::PERIODS.product(PricingQuery::HOTELS, PricingQuery::ROOMS).map.with_index do |(period, hotel, room), i|
      { "period" => period, "hotel" => hotel, "room" => room, "rate" => (10_000 + i).to_s }
    end
  end

  def stale_rates
    PricingQuery::PERIODS.product(PricingQuery::HOTELS, PricingQuery::ROOMS).each_with_object({}) do |(period, hotel, room), h|
      h[[ period, hotel, room ]] = "9999"
    end
  end

  def seed_stale_snapshot
    travel_to(10.minutes.ago) { RateSnapshot.write(stale_rates) }
    RateSnapshot.read
  end

  # Seeds a stale snapshot, lets the caller stub the failing upstream
  # condition, hits the endpoint, and asserts all three matrix requirements:
  # 503 with a matching message, exact retry count, and byte-identical
  # snapshot before/after.
  def assert_upstream_failure_yields_503(expected_request_count:, message_pattern:)
    original = seed_stale_snapshot
    original_bytes = Marshal.dump(original)

    yield

    get api_v1_pricing_url, params: VALID_PARAMS

    assert_response :service_unavailable
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_match message_pattern, json_response["error"]

    assert_requested :post, PRICING_UPSTREAM_URL, times: expected_request_count

    assert_equal original_bytes, Marshal.dump(RateSnapshot.read),
      "existing snapshot must be byte-for-byte unchanged"
  end

  test "timeout yields 503, leaves snapshot untouched, retries exactly once" do
    assert_upstream_failure_yields_503(expected_request_count: 2, message_pattern: /timed out/i) do
      stub_request(:post, PRICING_UPSTREAM_URL).to_timeout
    end
  end

  test "connection refused yields 503, leaves snapshot untouched, retries exactly once" do
    assert_upstream_failure_yields_503(expected_request_count: 2, message_pattern: /connection.*failed|refused/i) do
      stub_request(:post, PRICING_UPSTREAM_URL).to_raise(Errno::ECONNREFUSED)
    end
  end

  test "500 yields 503, leaves snapshot untouched, retries exactly once" do
    assert_upstream_failure_yields_503(expected_request_count: 2, message_pattern: /500/) do
      stub_request(:post, PRICING_UPSTREAM_URL).to_return(status: 500, body: { error: "boom" }.to_json)
    end
  end

  test "429 yields 503, leaves snapshot untouched, does not retry" do
    assert_upstream_failure_yields_503(expected_request_count: 1, message_pattern: /429|rate limit/i) do
      stub_request(:post, PRICING_UPSTREAM_URL).to_return(status: 429, body: { error: "Rate limit exceeded (1000/day)" }.to_json)
    end
  end

  test "401 yields 503, leaves snapshot untouched, does not retry" do
    assert_upstream_failure_yields_503(expected_request_count: 1, message_pattern: /401/) do
      stub_request(:post, PRICING_UPSTREAM_URL).to_return(status: 401, body: { error: "Unauthorized" }.to_json)
    end
  end

  test "malformed JSON yields 503, leaves snapshot untouched, does not retry" do
    assert_upstream_failure_yields_503(expected_request_count: 1, message_pattern: /JSON/i) do
      stub_request(:post, PRICING_UPSTREAM_URL).to_return(status: 200, body: "{not valid json")
    end
  end

  test "200 with 35 rates yields 503, leaves snapshot untouched, does not retry" do
    assert_upstream_failure_yields_503(expected_request_count: 1, message_pattern: /35/) do
      payload = valid_rates_payload[0..-2]
      stub_request(:post, PRICING_UPSTREAM_URL).to_return(status: 200, body: { rates: payload }.to_json)
    end
  end

  test "200 with a non-numeric rate yields 503, leaves snapshot untouched, does not retry" do
    assert_upstream_failure_yields_503(expected_request_count: 1, message_pattern: /non-numeric/i) do
      payload = valid_rates_payload
      payload.first["rate"] = "not-a-number"
      stub_request(:post, PRICING_UPSTREAM_URL).to_return(status: 200, body: { rates: payload }.to_json)
    end
  end
end
