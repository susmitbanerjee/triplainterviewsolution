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

  # Swaps Rails.logger for one that writes exactly the given message per
  # line (no Logger timestamp/severity prefix), so StructuredLogger's JSON
  # lines can be parsed back out directly. Returns the captured output.
  def capture_structured_logs
    original_logger = Rails.logger
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" }
    Rails.logger = logger
    yield
    io.string
  ensure
    Rails.logger = original_logger
  end
end
