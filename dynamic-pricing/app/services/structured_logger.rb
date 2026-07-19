# Single-line JSON logging, kept intentionally tiny: no lograge/semantic_logger
# dependency, just Rails.logger with a JSON-serialized message per call.
module StructuredLogger
  def self.info(event:, **fields)
    log(:info, event: event, **fields)
  end

  def self.warn(event:, **fields)
    log(:warn, event: event, **fields)
  end

  def self.log(level, event:, **fields)
    Rails.logger.public_send(level, { event: event, **fields }.to_json)
  end
end
