# A snapshot is { fetched_at:, rates: { [period, hotel, room] => rate } },
# read and written as a single object under ONE Rails.cache key. Because the
# whole payload lives behind one key, a reader's #read either gets a
# complete prior snapshot or a complete new one — there is no key under
# which only *some* of the 36 rates have been updated. Atomicity comes from
# the cache backend's own get/set on that single key, not from any locking
# here; coordinating concurrent refreshes (single-flight) is a different
# class's job.
class RateSnapshot
  CACHE_KEY = "pricing:snapshot"
  FRESH_FOR = 5.minutes

  # Deliberately longer than FRESH_FOR: freshness is enforced by #fresh?, not
  # by cache eviction. Keeping the stale entry around after the 5-minute
  # window lets callers observe "we have a snapshot, but it's stale" (and log
  # it) rather than seeing a bare nil indistinguishable from "never fetched".
  CACHE_TTL = 15.minutes

  attr_reader :fetched_at, :rates

  def self.write(rates_hash)
    snapshot = new(fetched_at: Time.current, rates: rates_hash)
    written = Rails.cache.write(CACHE_KEY, snapshot, expires_in: CACHE_TTL)
    written ? snapshot : nil
  end

  def self.read
    Rails.cache.read(CACHE_KEY)
  end

  def initialize(fetched_at:, rates:)
    @fetched_at = fetched_at
    @rates = rates
  end

  def fresh?
    Time.current - fetched_at <= FRESH_FOR
  end

  def rate_for(period:, hotel:, room:)
    rates[[ period, hotel, room ]]
  end
end
