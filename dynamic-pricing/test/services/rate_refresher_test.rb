require "test_helper"

class RateRefresherTest < ActiveSupport::TestCase
  PRICING_URL = "#{Rails.application.config.x.rate_api.url}/pricing".freeze

  def sample_rates
    { [ "Summer", "FloatingPointResort", "SingletonRoom" ] => "15000" }
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

  test "waiting requests do not re-attempt when the winner's refresh fails, and fail fast via the cooldown marker" do
    write_stale_snapshot
    original = RateSnapshot.read

    request_count = 0
    count_mutex = Mutex.new

    stub_request(:post, PRICING_URL).to_return do
      count_mutex.synchronize { request_count += 1 }
      { status: 500, body: { error: "boom" }.to_json }
    end

    threads = 10.times.map do
      Thread.new do
        begin
          RateRefresher.ensure_fresh!
        rescue RateRefresher::Error => e
          e
        end
      end
    end
    results = threads.map(&:value)

    # Exactly the winner's two attempts (MAX_ATTEMPTS) — no waiting thread
    # ever calls acquire_lock again after losing the race, so a failed
    # refresh does not turn into a stampede of retries.
    assert_equal 2, request_count
    assert_requested :post, PRICING_URL, times: 2

    assert_equal 10, results.size
    assert results.all? { |r| r.is_a?(RateRefresher::Error) },
      "expected every thread to end in a RateRefresher::Error, got: #{results.map(&:class).uniq}"

    # The winner sees its own failure directly; the nine losers, once the
    # winner writes the failure marker, see the cooldown on their next poll
    # tick instead of waiting out the full POLL_TIMEOUT.
    refresh_failed_count = results.count { |r| r.is_a?(RateRefresher::RefreshFailed) }
    cooling_down_count = results.count { |r| r.is_a?(RateRefresher::CoolingDown) }
    assert_equal 1, refresh_failed_count, "exactly one thread (the winner) should see RefreshFailed"
    assert_equal 9, cooling_down_count, "the other nine (losers) should fail fast via the cooldown marker"

    unchanged = RateSnapshot.read
    assert_equal original.fetched_at, unchanged.fetched_at
    assert_equal original.rates, unchanged.rates
  end

  test "a failed refresh starts a cooldown; sequential requests within it fail fast with no additional upstream attempts" do
    write_stale_snapshot
    stub_request(:post, PRICING_URL).to_return(status: 500, body: { error: "boom" }.to_json)

    assert_raises(RateRefresher::RefreshFailed) { RateRefresher.ensure_fresh! }
    assert_requested :post, PRICING_URL, times: 2

    3.times do
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(RateRefresher::CoolingDown) { RateRefresher.ensure_fresh! }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_operator elapsed, :<, RateRefresher::POLL_TIMEOUT,
        "fast-fail should not wait out the poll timeout"
      assert_kind_of Integer, error.retry_after
      assert_operator error.retry_after, :>, 0
    end

    assert_requested :post, PRICING_URL, times: 2
  end

  test "cooldown expires after FAILURE_COOLDOWN and the next request attempts a refresh again" do
    write_stale_snapshot
    stub_request(:post, PRICING_URL).to_return(status: 500, body: { error: "boom" }.to_json)

    assert_raises(RateRefresher::RefreshFailed) { RateRefresher.ensure_fresh! }
    assert_requested :post, PRICING_URL, times: 2

    travel(RateRefresher::FAILURE_COOLDOWN + 1.second) do
      assert_raises(RateRefresher::RefreshFailed) { RateRefresher.ensure_fresh! }
    end

    assert_requested :post, PRICING_URL, times: 4
  end

  test "a successful refresh clears the cooldown for the next window" do
    write_stale_snapshot
    stub_request(:post, PRICING_URL)
      .to_return(status: 500, body: { error: "boom" }.to_json)
      .then.to_return(status: 500, body: { error: "boom" }.to_json)
      .then.to_return(status: 200, body: { rates: valid_rates_payload }.to_json)

    assert_raises(RateRefresher::RefreshFailed) { RateRefresher.ensure_fresh! }
    assert_requested :post, PRICING_URL, times: 2

    travel(RateRefresher::FAILURE_COOLDOWN + 1.second) do
      result = RateRefresher.ensure_fresh!
      assert result.fresh?
    end

    assert_requested :post, PRICING_URL, times: 3
    assert_nil Rails.cache.read(RateRefresher::FAILURE_KEY)
  end

  test "a failed snapshot write is treated as a failed refresh: cooldown marker, no success log, RefreshFailed raised" do
    write_stale_snapshot
    stub_request(:post, PRICING_URL).to_return(status: 200, body: { rates: valid_rates_payload }.to_json)

    logs = capture_structured_logs do
      RateSnapshot.stub(:write, nil) do
        assert_raises(RateRefresher::RefreshFailed) { RateRefresher.ensure_fresh! }
      end
    end

    entry = JSON.parse(logs.lines.find { |l| l.include?('"event":"rates.refresh"') })
    assert_equal "publication_failed", entry["outcome"]

    assert_not_nil Rails.cache.read(RateRefresher::FAILURE_KEY),
      "expected a cooldown marker to be recorded even though the fetch itself succeeded"

    error = assert_raises(RateRefresher::CoolingDown) { RateRefresher.ensure_fresh! }
    assert_kind_of Integer, error.retry_after
  end

  test "a contender parked between the pre-lock cooldown check and lock acquisition re-checks cooldown after acquiring the freed lock, and spends no additional upstream attempts" do
    write_stale_snapshot
    stub_request(:post, PRICING_URL).to_return(status: 500, body: { error: "boom" }.to_json)

    contender_parked = Queue.new
    release_contender = Queue.new

    # Parks the contender right after it passes the pre-lock cooldown check
    # and right before it calls acquire_lock, deterministically, so the
    # winner can acquire, fail, and publish a cooldown marker in between.
    RateRefresher.before_lock_acquisition_hook = lambda do
      contender_parked << true
      release_contender.pop
    end

    contender = Thread.new do
      RateRefresher.ensure_fresh!
    rescue RateRefresher::Error => e
      e
    end

    contender_parked.pop

    RateRefresher.before_lock_acquisition_hook = -> { } # the winner must not stall on the same hook

    winner_result =
      begin
        RateRefresher.ensure_fresh!
      rescue RateRefresher::Error => e
        e
      end

    release_contender << true
    contender_result = contender.value

    assert_kind_of RateRefresher::RefreshFailed, winner_result
    assert_kind_of RateRefresher::CoolingDown, contender_result
    assert_requested :post, PRICING_URL, times: 2
  ensure
    RateRefresher.before_lock_acquisition_hook = -> { }
  end

  test "record_failure! logs a WARN when the marker write fails, and the original refresh error still propagates" do
    write_stale_snapshot
    stub_request(:post, PRICING_URL).to_return(status: 500, body: { error: "boom" }.to_json)

    original_write = Rails.cache.method(:write)
    fail_marker_write = lambda do |key, *rest, **kwargs|
      key == RateRefresher::FAILURE_KEY ? false : original_write.call(key, *rest, **kwargs)
    end

    logs = capture_structured_logs do
      Rails.cache.stub(:write, fail_marker_write) do
        assert_raises(RateRefresher::RefreshFailed) { RateRefresher.ensure_fresh! }
      end
    end

    entry = JSON.parse(logs.lines.find { |l| l.include?('"event":"rates.refresh_marker_failed"') })
    assert_equal "rates.refresh_marker_failed", entry["event"]
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

  test "logs outcome: authentication_error on a 401, distinct from generic upstream_error" do
    write_stale_snapshot
    stub_request(:post, PRICING_URL).to_return(status: 401, body: { error: "Unauthorized" }.to_json)

    logs = capture_structured_logs do
      assert_raises(RateRefresher::RefreshFailed) { RateRefresher.ensure_fresh! }
    end

    entry = JSON.parse(logs.lines.find { |l| l.include?('"event":"rates.refresh"') })
    assert_equal "authentication_error", entry["outcome"]
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
