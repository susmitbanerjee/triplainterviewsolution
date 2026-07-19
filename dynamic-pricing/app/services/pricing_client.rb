class PricingClient
  class Error < StandardError; end
  class Timeout < Error; end
  class ConnectionError < Error; end
  class UpstreamError < Error; end
  class RateLimited < UpstreamError; end
  class InvalidResponse < Error; end

  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 3
  MAX_ATTEMPTS = 2
  RETRY_BASE_DELAY = 0.1

  UNIVERSE = PricingQuery::PERIODS.product(PricingQuery::HOTELS, PricingQuery::ROOMS).freeze

  def self.fetch_all
    new.fetch_all
  end

  def fetch_all
    handle_response(request_with_retries)
  end

  private

  # Retries only on timeout or 5xx, at most once total. 4xx (including 429,
  # handled specially by the caller) never retries: a bad token or a blown
  # daily quota won't heal by trying again, and retrying burns quota.
  def request_with_retries
    response = nil

    MAX_ATTEMPTS.times do |i|
      attempt = i + 1

      begin
        response = post_batch
      rescue ::Timeout::Error => e
        raise Timeout, "Pricing upstream timed out after #{attempt} attempt(s): #{e.message}" if attempt == MAX_ATTEMPTS

        sleep(jittered_delay)
        next
      rescue Errno::ECONNREFUSED => e
        raise ConnectionError, "Pricing upstream connection failed after #{attempt} attempt(s): #{e.class}: #{e.message}" if attempt == MAX_ATTEMPTS

        sleep(jittered_delay)
        next
      end

      break unless server_error?(response)
      break if attempt == MAX_ATTEMPTS

      sleep(jittered_delay)
    end

    response
  end

  def post_batch
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

  def handle_response(response)
    case response.code
    when 429
      raise RateLimited, "Upstream rate limit exceeded (429): #{response.body}"
    when 200
      parse_rates(response.body)
    else
      raise UpstreamError, "Upstream returned unexpected status #{response.code}: #{response.body}"
    end
  end

  def parse_rates(raw_body)
    parsed = JSON.parse(raw_body)
    rates = parsed["rates"]
    raise InvalidResponse, "Response missing a \"rates\" array" unless rates.is_a?(Array)
    raise InvalidResponse, "Expected #{UNIVERSE.size} rates, got #{rates.size}" unless rates.size == UNIVERSE.size

    result = {}
    rates.each do |entry|
      raise InvalidResponse, "Rate entry is not an object: #{entry.inspect}" unless entry.is_a?(Hash)

      key = [entry["period"], entry["hotel"], entry["room"]]
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
