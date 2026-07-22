class StaySaga < SagaForge::Base
  # Structural dedup (saga_class, correlation_id, event_name) means a single
  # instance can never receive two rows of the same event_name, so looping
  # via `stay` now needs a distinct event per lap rather than redelivering
  # `tick`: tick_a stays in :counting, tick_b lets the chain advance.
  correlate_by :counter_id

  start_with(:start_counting) { |saga, _payload| saga.context[:n] = 0 }

  during(:counting, on: :tick_a) do |saga, _payload|
    saga.context[:n] = saga.context[:n].to_i + 1
    saga.stay
  end

  during(:counting, on: :tick_b) do |saga, _payload|
    saga.context[:n] = saga.context[:n].to_i + 1
  end

  finish_with :done_counting
end
