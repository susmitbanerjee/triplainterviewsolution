class PricingClient
  class Error < StandardError; end
  class Timeout < Error; end
  class ConnectionError < Error; end
  class UpstreamError < Error; end
  class RateLimited < UpstreamError; end
  class AuthenticationError < Error; end
  class InvalidResponse < Error; end

  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 3
  MAX_ATTEMPTS = 2
  RETRY_BASE_DELAY = 0.1

  UNIVERSE = PricingQuery::PERIODS.product(PricingQuery::HOTELS, PricingQuery::ROOMS).freeze

  UPSTREAM_CALLS_CACHE_PREFIX = "pricing:upstream_calls"
  UPSTREAM_CALLS_TTL = 48.hours
  # Worst case under correct single-flight coordination is 288 refresh
  # windows/day x up to MAX_ATTEMPTS (2) attempts each = 576 calls, against a
  # 1,000/day upstream budget. Anything past 500 means that guarantee is
  # broken — something is causing more than one attempt sequence per window.
  UPSTREAM_CALLS_WARN_THRESHOLD = 500

  def self.fetch_all
    new.fetch_all
  end

  def self.upstream_calls_today
    Rails.cache.read(upstream_calls_cache_key) || 0
  end

  def self.upstream_calls_cache_key(date = Date.current)
    "#{UPSTREAM_CALLS_CACHE_PREFIX}:#{date}"
  end

  def fetch_all
    request_with_retries
  end

  private

  # Retries once on timeout, connection error, 5xx, or a content-validation
  # failure (InvalidResponse) — recon (docs/recon-notes.md) shows the
  # fake-success 200s that trip InvalidResponse are transient, roughly
  # 5-10% of all calls, and succeed on an identical retry. Never retries
  # 429 or other 4xx (401 included): a bad token or a blown daily quota
  # won't heal by trying again, and retrying only burns more of the budget.
  def request_with_retries
    MAX_ATTEMPTS.times do |i|
      attempt = i + 1
      last_attempt = attempt == MAX_ATTEMPTS

      begin
        response = post_batch
      rescue ::Timeout::Error => e
        raise Timeout, "Pricing upstream timed out after #{attempt} attempt(s): #{e.message}" if last_attempt

        sleep(jittered_delay)
        next
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
             SocketError, EOFError, OpenSSL::SSL::SSLError => e
        raise ConnectionError, "Pricing upstream connection failed after #{attempt} attempt(s): #{e.class}: #{e.message}" if last_attempt

        sleep(jittered_delay)
        next
      end

      case response.code
      when 429
        raise RateLimited, "Upstream rate limit exceeded (429): #{response.body}"
      when 401
        raise AuthenticationError, "Upstream rejected the API token (401) — check RATE_API_TOKEN"
      when 200
        begin
          return parse_rates(response.body)
        rescue InvalidResponse
          raise if last_attempt

          sleep(jittered_delay)
        end
      else
        if server_error?(response) && !last_attempt
          sleep(jittered_delay)
          next
        end

        raise UpstreamError, "Upstream returned unexpected status #{response.code}: #{response.body}"
      end
    end
  end

  def post_batch
    record_upstream_call!

    HTTParty.post(
      pricing_url,
      headers: {
        "Content-Type" => "application/json",
        "token" => token
      },
      body: request_body,
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT
    )
  end

  # Counts every actual HTTP attempt, including retries — incremented before
  # the request goes out, not after, so a hung/timed-out attempt still counts.
  def record_upstream_call!
    count = Rails.cache.increment(self.class.upstream_calls_cache_key, 1, expires_in: UPSTREAM_CALLS_TTL)
    return unless count && count > UPSTREAM_CALLS_WARN_THRESHOLD

    StructuredLogger.warn(
      event: "pricing.upstream_calls_exceeded",
      upstream_calls_today: count,
      threshold: UPSTREAM_CALLS_WARN_THRESHOLD
    )
  end

  def pricing_url
    "#{Rails.application.config.x.rate_api.url}/pricing"
  end

  def token
    Rails.application.config.x.rate_api.token
  end

  def request_body
    {
      attributes: UNIVERSE.map { |period, hotel, room| { period:, hotel:, room: } }
    }.to_json
  end

  def server_error?(response)
    (500..599).cover?(response.code)
  end

  def parse_rates(raw_body)
    parsed = JSON.parse(raw_body)
    rates = parsed["rates"]
    raise InvalidResponse, "Response missing a \"rates\" array" unless rates.is_a?(Array)
    raise InvalidResponse, "Expected #{UNIVERSE.size} rates, got #{rates.size}" unless rates.size == UNIVERSE.size

    result = {}
    rates.each do |entry|
      raise InvalidResponse, "Rate entry is not an object: #{entry.inspect}" unless entry.is_a?(Hash)

      key = [ entry["period"], entry["hotel"], entry["room"] ]
      raise InvalidResponse, "Unexpected attribute combination: #{key.inspect}" unless UNIVERSE.include?(key)
      raise InvalidResponse, "Duplicate rate entry for #{key.inspect}" if result.key?(key)

      rate = entry["rate"]
      raise InvalidResponse, "Non-numeric rate for #{key.inspect}: #{rate.inspect}" unless numeric_rate?(rate)

      result[key] = rate.to_s
    end

    result
  rescue JSON::ParserError => e
    raise InvalidResponse, "Upstream response was not valid JSON: #{e.message}"
  end

  # The documented contract is a numeric string, but the real simulator mixes
  # in JSON integers for the same field (see recon notes) — accept either
  # representation as long as it is actually numeric, and normalize to string.
  def numeric_rate?(value)
    case value
    when String
      value.match?(/\A\d+(\.\d+)?\z/)
    when Integer
      value >= 0
    when Float
      value.finite? && value >= 0
    else
      false
    end
  end

  def jittered_delay
    RETRY_BASE_DELAY + (rand * RETRY_BASE_DELAY)
  end
end
