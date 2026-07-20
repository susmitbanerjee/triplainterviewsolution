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

  # Raised when a recent refresh failure is still within its cooldown (see
  # FAILURE_COOLDOWN). Carries retry_after (seconds, rounded up) so the
  # controller can surface a Retry-After header instead of just a 503.
  class CoolingDown < Error
    attr_reader :retry_after

    def initialize(retry_after)
      @retry_after = retry_after
      super("Upstream is failing — retry after cooldown (#{retry_after}s remaining)")
    end
  end

  LOCK_KEY = "pricing:refresh_lock"
  FAILURE_KEY = "pricing:refresh_failure"

  # PricingClient's worst case is ~2 attempts x (2s open + 3s read timeout)
  # plus a short jittered retry sleep, i.e. roughly 10-10.5s. LOCK_TTL must
  # comfortably outlive that so a *legitimately* still-working holder is
  # never mistaken for a crashed one, while still being short enough that a
  # genuinely crashed holder doesn't wedge refreshes for long.
  LOCK_TTL = 15.seconds

  POLL_TIMEOUT = 3.seconds
  POLL_INTERVAL = 0.1

  # How long a failed refresh blocks new attempt-sequences, success or
  # failure. Without this, a failed refresh released the lock with no
  # record of the failure, so the very next request became a new winner and
  # spent 2 more upstream attempts — under steady traffic against a
  # persistently failing upstream, calls scale with REQUEST RATE, not
  # windows, and the 1,000/day quota was gone in about an hour. Set to
  # match RateSnapshot::FRESH_FOR (5 minutes) so the invariant is simple:
  # refresh attempt-sequences are spaced >= 5 minutes apart, success OR
  # failure, unconditionally — at most 288 attempt-sequences and 576 raw
  # upstream calls a day, even if upstream is down for the entire day.
  FAILURE_COOLDOWN = 5.minutes

  # Test-only seam: called between the pre-lock cooldown check and lock
  # acquisition in ensure_fresh!. A no-op in production; tests override it
  # to park a thread deterministically inside that exact window (someone
  # else acquires the lock, fails, and publishes a cooldown marker before
  # the parked thread resumes) instead of relying on a sleep-based race
  # that only passes by luck.
  mattr_accessor :before_lock_acquisition_hook, default: -> { }

  def self.ensure_fresh!
    new.ensure_fresh!
  end

  def ensure_fresh!
    snapshot = RateSnapshot.read
    return snapshot if snapshot&.fresh?

    raise_if_cooling_down!

    before_lock_acquisition_hook.call

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

    # Same double-checked pattern as the freshness re-check above, and for
    # the same reason: raise_if_cooling_down! already ran before lock
    # acquisition (ensure_fresh!), but another holder can acquire the lock,
    # fail, and publish a cooldown marker in the window between that check
    # and this call actually acquiring the lock. Any condition checked
    # before lock acquisition can change before acquisition succeeds, so
    # every pre-lock guard must be re-verified post-lock.
    raise_if_cooling_down!

    started_at = monotonic_now

    begin
      rates = PricingClient.fetch_all
    rescue PricingClient::Error => e
      log_refresh(outcome: outcome_for(e), started_at:)
      record_failure!
      # Existing snapshot (stale or otherwise) is left exactly as-is.
      raise RefreshFailed, "Failed to refresh pricing snapshot: #{e.class}: #{e.message}"
    end

    # Write before logging success: a publication failure is a failed
    # refresh too (same cooldown, no success line), not a fetch that
    # quietly never made it into the snapshot.
    written = RateSnapshot.write(rates)
    unless written
      log_refresh(outcome: "publication_failed", started_at:)
      record_failure!
      raise RefreshFailed, "Failed to refresh pricing snapshot: snapshot publication failed"
    end

    Rails.cache.delete(FAILURE_KEY)
    log_refresh(outcome: "success", started_at:)
    written
  end

  def outcome_for(error)
    case error
    when PricingClient::RateLimited
      "rate_limited"
    when PricingClient::AuthenticationError
      "authentication_error"
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

  def record_failure!
    written = Rails.cache.write(FAILURE_KEY, Time.current, expires_in: FAILURE_COOLDOWN)
    return if written

    # A false write here means no cooldown marker exists, so the next
    # request will treat upstream as untested and retry immediately,
    # quietly weakening the unconditional attempt-sequence spacing
    # guarantee FAILURE_COOLDOWN above depends on. This does not change
    # what gets raised to the caller: the original refresh error still
    # propagates unchanged. This is purely an additional signal that the
    # safety net itself failed to record.
    StructuredLogger.warn(event: "rates.refresh_marker_failed")
  end

  # Checked before lock acquisition (ensure_fresh!), again immediately after
  # acquiring it (refresh_if_still_stale) since a cooldown can start in the
  # gap between those two checks, and again on every poll tick
  # (wait_for_fresh_snapshot) so a losing thread doesn't wait out the full
  # poll timeout once it's clear the winner already failed.
  def raise_if_cooling_down!
    failed_at = Rails.cache.read(FAILURE_KEY)
    return unless failed_at

    remaining = (FAILURE_COOLDOWN - (Time.current - failed_at)).ceil
    raise CoolingDown.new(remaining) if remaining.positive?
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

      raise_if_cooling_down!

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
