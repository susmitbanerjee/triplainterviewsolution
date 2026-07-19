ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require "webmock/minitest"

WebMock.disable_net_connect!

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: 1)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Rails.cache is now a real MemoryStore (see config/environments/test.rb) and
  # persists across test cases within this process, so clear it between tests.
  setup { Rails.cache.clear }

  # Add more helper methods to be used by all tests here...
end
