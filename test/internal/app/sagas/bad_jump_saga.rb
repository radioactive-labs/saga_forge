# Throwaway fixture for exercising the UnknownStateError runtime-validation
# path (§A.8): its during-handler jumps to a state that was never declared.
class BadJumpSaga < SagaForge::Base
  correlate_by :bad_jump_id

  start_with(:bad_jump_started) { |saga, _payload| }

  during(:mid, on: :bad_jump_tick) do |saga, _payload|
    saga.transition_to :nonexistent
  end

  finish_with :done
end
