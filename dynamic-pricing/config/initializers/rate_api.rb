Rails.application.config.x.rate_api = ActiveSupport::OrderedOptions.new
Rails.application.config.x.rate_api.url = ENV.fetch("RATE_API_URL")
Rails.application.config.x.rate_api.token = ENV.fetch("RATE_API_TOKEN")
