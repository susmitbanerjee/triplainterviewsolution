require "test_helper"

class RateSnapshotTest < ActiveSupport::TestCase
  BASE_TIME = Time.zone.parse("2026-01-01 12:00:00")

  def sample_rates
    { ["Summer", "FloatingPointResort", "SingletonRoom"] => "15000" }
  end

  test "read returns nil when nothing has been written" do
    assert_nil RateSnapshot.read
  end

  test "write stamps fetched_at with the current time and stores the rates" do
    travel_to(BASE_TIME) do
      RateSnapshot.write(sample_rates)

      snapshot = RateSnapshot.read
      assert_equal BASE_TIME, snapshot.fetched_at
      assert_equal sample_rates, snapshot.rates
    end
  end

  test "rate_for returns the rate for a known combination and nil for an unknown one" do
    travel_to(BASE_TIME) do
      RateSnapshot.write(sample_rates)
      snapshot = RateSnapshot.read

      assert_equal "15000", snapshot.rate_for(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
      assert_nil snapshot.rate_for(period: "Winter", hotel: "GitawayHotel", room: "BooleanTwin")
    end
  end

  test "fresh? is true at 4 minutes 59 seconds old" do
    travel_to(BASE_TIME) { RateSnapshot.write(sample_rates) }

    travel_to(BASE_TIME + 4.minutes + 59.seconds) do
      assert RateSnapshot.read.fresh?
    end
  end

  test "fresh? is true at exactly 5 minutes old (boundary is inclusive)" do
    travel_to(BASE_TIME) { RateSnapshot.write(sample_rates) }

    travel_to(BASE_TIME + 5.minutes) do
      assert RateSnapshot.read.fresh?
    end
  end

  test "fresh? is false at 5 minutes 1 second old" do
    travel_to(BASE_TIME) { RateSnapshot.write(sample_rates) }

    travel_to(BASE_TIME + 5.minutes + 1.second) do
      assert_not RateSnapshot.read.fresh?
    end
  end

  test "the cache entry outlives the freshness window so staleness can be observed" do
    travel_to(BASE_TIME) { RateSnapshot.write(sample_rates) }

    travel_to(BASE_TIME + 6.minutes) do
      snapshot = RateSnapshot.read
      assert_not_nil snapshot
      assert_not snapshot.fresh?
    end
  end

  test "the cache entry itself expires after CACHE_TTL" do
    travel_to(BASE_TIME) { RateSnapshot.write(sample_rates) }

    travel_to(BASE_TIME + RateSnapshot::CACHE_TTL + 1.second) do
      assert_nil RateSnapshot.read
    end
  end
end
