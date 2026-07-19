# Coordinates refreshing the single RateSnapshot: at most one in-flight
# upstream fetch at a time, via a lock built on Rails.cache.
#
# Store in this scaffold: Rails.cache is configured as :memory_store (see
# config/environments/{development,test}.rb) — in-process only, not shared
# across OS processes. The lock below is implemented as an atomic
# "SET-if-absent-with-TTL" on Rails.cache (Rails.cache.write with
# unless_exist: true and expires_in:), which is the same primitive as a
# Redis `SET NX EX` and is portable to Redis/Memcached/Solid Cache without
# changing this class. Given the actual store here is MemoryStore, this is
# effectively the "single-process fallback": a plain Ruby Mutex would give
# the same correctness *within* this process, but couldn't express a TTL (a
# Mutex has no notion of "expired"), and this app currently only ever runs
# as one process anyway. If this ever runs multi-process/multi-host, the
# store needs to become a real shared backend (Redis, Solid Cache, etc.) —
# at which point this same locking code keeps working unchanged.
class RateRefresher
  class Error < StandardError; end
  class Unavailable < Error; end
  class RefreshFailed < Error; end

  LOCK_KEY = "pricing:refresh_lock"

  # PricingClient's worst case is ~2 attempts x (2s open + 3s read timeout)
  # plus a short jittered retry sleep, i.e. roughly 10-10.5s. LOCK_TTL must
  # comfortably outlive that so a *legitimately* still-working holder is
  # never mistaken for a crashed one, while still being short enough that a
  # genuinely crashed holder doesn't wedge refreshes for long.
  LOCK_TTL = 15.seconds

  POLL_TIMEOUT = 3.seconds
  POLL_INTERVAL = 0.1

  def self.ensure_fresh!
    new.ensure_fresh!
  end

  def ensure_fresh!
    snapshot = RateSnapshot.read
    return snapshot if snapshot&.fresh?

    token = acquire_lock
    return wait_for_fresh_snapshot unless token

    begin
      refresh_if_still_stale
    ensure
      release_lock(token)
    end
  end

  private

  # Runs only while holding the lock. Re-checks freshness first: another
  # holder may have refreshed and released between our first read above and
  # our acquiring the lock (e.g. we acquired it only because they had just
  # released it). This re-check is the structural guarantee that
  # PricingClient.fetch_all is invoked at most once per freshness window
  # (288/day): it is reachable only from inside this method, only while
  # holding the lock, only when the snapshot is still stale. PricingClient's
  # own retry policy can turn each invocation into up to 2 raw upstream
  # calls, for a 576/day worst case — see PricingClient::UPSTREAM_CALLS_WARN_THRESHOLD.
  def refresh_if_still_stale
    snapshot = RateSnapshot.read
    return snapshot if snapshot&.fresh?

    started_at = monotonic_now

    begin
      rates = PricingClient.fetch_all
    rescue PricingClient::Error => e
      log_refresh(outcome: outcome_for(e), started_at:)
      # Existing snapshot (stale or otherwise) is left exactly as-is.
      raise RefreshFailed, "Failed to refresh pricing snapshot: #{e.class}: #{e.message}"
    end

    log_refresh(outcome: "success", started_at:)
    RateSnapshot.write(rates)
  end

  def outcome_for(error)
    case error
    when PricingClient::RateLimited
      "rate_limited"
    when PricingClient::InvalidResponse
      "invalid_response"
    when PricingClient::Timeout, PricingClient::ConnectionError
      "timeout"
    else
      "upstream_error"
    end
  end

  def log_refresh(outcome:, started_at:)
    StructuredLogger.info(
      event: "rates.refresh",
      outcome: outcome,
      duration_ms: elapsed_ms(started_at),
      upstream_calls_today: PricingClient.upstream_calls_today
    )
  end

  def acquire_lock
    token = SecureRandom.uuid
    acquired = Rails.cache.write(LOCK_KEY, token, unless_exist: true, expires_in: LOCK_TTL)
    acquired ? token : nil
  end

  def release_lock(token)
    # Only release the lock if we still hold it. Guards against deleting a
    # lock that expired and was re-acquired by someone else while we were
    # unexpectedly slow (this read-then-delete pair isn't perfectly atomic,
    # but the window is a couple of Ruby method calls, and LOCK_TTL is sized
    # to make that irrelevant in practice).
    Rails.cache.delete(LOCK_KEY) if Rails.cache.read(LOCK_KEY) == token
  end

  def wait_for_fresh_snapshot
    deadline = monotonic_now + POLL_TIMEOUT

    while monotonic_now < deadline
      snapshot = RateSnapshot.read
      return snapshot if snapshot&.fresh?

      sleep POLL_INTERVAL
    end

    raise Unavailable, "Pricing data is stale and no refresh completed within #{POLL_TIMEOUT}s"
  end

  # Process.clock_gettime(:MONOTONIC), unlike Time.current, is not affected
  # by ActiveSupport::Testing::TimeHelpers#travel_to, so polling always waits
  # in real wall-clock time regardless of any simulated time elsewhere.
  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started_at)
    ((monotonic_now - started_at) * 1000).round
  end
end
