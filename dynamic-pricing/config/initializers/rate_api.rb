Rails.application.config.x.rate_api = ActiveSupport::OrderedOptions.new
Rails.application.config.x.rate_api.url = ENV.fetch("RATE_API_URL", "http://localhost:8080")
Rails.application.config.x.rate_api.token = ENV.fetch("RATE_API_TOKEN", "04aa6f42aa03f220c2ae9a276cd68c62")
