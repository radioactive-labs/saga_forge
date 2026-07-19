# Throwaway fixture for retry-policy integration coverage (Task 7): its
# start handler raises different errors depending on payload[:mode] so tests
# can exercise retryable, exhausted, unmatched, and subclass-routed paths
# against a composite retry policy.
class FlakySaga < SagaForge::Base
  class FlakyError < StandardError; end

  class SubFlakyError < FlakyError; end

  class FatalError < StandardError; end

  correlate_by :id
  retry_policy SagaForge::RetryPolicy.new(retry_on: [FlakyError], max_attempts: 3),
    SagaForge::RetryPolicy.new(retry_on: [FatalError], max_attempts: 1)

  start_with :flaky_started do |saga, payload|
    raise FlakyError if payload[:mode] == "flaky"
    raise SubFlakyError if payload[:mode] == "sub_flaky"
    raise FatalError if payload[:mode] == "fatal"
    raise "unmatched" if payload[:mode] == "unmatched"
    raise FatalError, "bad byte \xFF in here".dup.force_encoding(Encoding::ASCII_8BIT) if payload[:mode] == "binary"
    saga.context[:ok] = true
  end
  finish_with :flaky_done
end
