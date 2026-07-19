require "test_helper"

class RateRefresherTest < ActiveSupport::TestCase
  PRICING_URL = "#{Rails.application.config.x.rate_api.url}/pricing".freeze

  def sample_rates
    { ["Summer", "FloatingPointResort", "SingletonRoom"] => "15000" }
  end

  def valid_rates_payload
    PricingQuery::PERIODS.product(PricingQuery::HOTELS, PricingQuery::ROOMS).map.with_index do |(period, hotel, room), i|
      { "period" => period, "hotel" => hotel, "room" => room, "rate" => (10_000 + i).to_s }
    end
  end

  def write_stale_snapshot(rates = sample_rates)
    travel_to(10.minutes.ago) { RateSnapshot.write(rates) }
  end

  test "N concurrent threads with an expired snapshot trigger exactly one upstream request" do
    write_stale_snapshot

    request_count = 0
    count_mutex = Mutex.new

    stub_request(:post, PRICING_URL).to_return do
      count_mutex.synchronize { request_count += 1 }
      sleep 0.2 # widen the race window so waiting threads actually hit the poll path
      { status: 200, body: { rates: valid_rates_payload }.to_json }
    end

    threads = 10.times.map { Thread.new { RateRefresher.ensure_fresh! } }
    results = threads.map(&:value)

    assert_equal 1, request_count
    assert_requested :post, PRICING_URL, times: 1

    results.each do |snapshot|
      assert snapshot.fresh?
      assert_equal 36, snapshot.rates.size
    end
  end

  test "double-check: lock acquired but snapshot already fresh makes zero upstream calls" do
    stale = RateSnapshot.new(fetched_at: 10.minutes.ago, rates: sample_rates)
    fresh = RateSnapshot.new(fetched_at: Time.current, rates: sample_rates)

    read_count = 0
    reader = lambda do
      read_count += 1
      read_count == 1 ? stale : fresh
    end

    result = RateSnapshot.stub(:read, reader) { RateRefresher.ensure_fresh! }

    assert_equal fresh, result
    assert_operator read_count, :>=, 2
    assert_not_requested :post, PRICING_URL
  end

  test "an upstream failure leaves the previous snapshot untouched, raises, and releases the lock" do
    write_stale_snapshot
    original = RateSnapshot.read

    stub_request(:post, PRICING_URL).to_return(status: 500, body: { error: "boom" }.to_json)

    error = assert_raises(RateRefresher::RefreshFailed) { RateRefresher.ensure_fresh! }
    assert_match(/PricingClient/, error.message)

    unchanged = RateSnapshot.read
    assert_equal original.fetched_at, unchanged.fetched_at
    assert_equal original.rates, unchanged.rates

    assert_nil Rails.cache.read(RateRefresher::LOCK_KEY)
  end

  test "a crashed holder's lock expires and the next call recovers" do
    write_stale_snapshot

    # Simulate a holder that acquired the lock and never released it.
    Rails.cache.write(RateRefresher::LOCK_KEY, "dead-holder-token", unless_exist: true, expires_in: RateRefresher::LOCK_TTL)

    stub_request(:post, PRICING_URL).to_return(status: 200, body: { rates: valid_rates_payload }.to_json)

    travel(RateRefresher::LOCK_TTL + 1.second) do
      result = RateRefresher.ensure_fresh!

      assert result.fresh?
      assert_equal 36, result.rates.size
    end

    assert_requested :post, PRICING_URL, times: 1
  end

  test "logs a structured rates.refresh line with outcome: success" do
    write_stale_snapshot
    stub_request(:post, PRICING_URL).to_return(status: 200, body: { rates: valid_rates_payload }.to_json)

    logs = capture_structured_logs { RateRefresher.ensure_fresh! }

    entry = JSON.parse(logs.lines.find { |l| l.include?('"event":"rates.refresh"') })
    assert_equal "rates.refresh", entry["event"]
    assert_equal "success", entry["outcome"]
    assert_kind_of Integer, entry["duration_ms"]
    assert_equal 1, entry["upstream_calls_today"]
  end

  test "logs a structured rates.refresh line with a condition-specific outcome on failure" do
    write_stale_snapshot
    stub_request(:post, PRICING_URL).to_return(status: 429, body: { error: "Rate limit exceeded (1000/day)" }.to_json)

    logs = capture_structured_logs do
      assert_raises(RateRefresher::RefreshFailed) { RateRefresher.ensure_fresh! }
    end

    entry = JSON.parse(logs.lines.find { |l| l.include?('"event":"rates.refresh"') })
    assert_equal "rate_limited", entry["outcome"]
  end

  test "does not log rates.refresh when the double-check finds the snapshot already fresh" do
    stale = RateSnapshot.new(fetched_at: 10.minutes.ago, rates: sample_rates)
    fresh = RateSnapshot.new(fetched_at: Time.current, rates: sample_rates)

    read_count = 0
    reader = lambda do
      read_count += 1
      read_count == 1 ? stale : fresh
    end

    logs = capture_structured_logs { RateSnapshot.stub(:read, reader) { RateRefresher.ensure_fresh! } }

    assert_nil logs.lines.find { |l| l.include?('"event":"rates.refresh"') }
  end
end
