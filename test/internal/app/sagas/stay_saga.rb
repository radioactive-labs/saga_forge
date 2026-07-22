class StaySaga < SagaForge::Base
  correlate_by :counter_id
  start_with(:start_counting) { |saga, _payload| saga.context[:n] = 0 }
  during(:counting, on: :tick) { |saga, _payload| saga.context[:n] = saga.context[:n].to_i + 1 }
  finish_with :done_counting
end
