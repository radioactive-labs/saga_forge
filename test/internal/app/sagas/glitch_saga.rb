# Fixture for durability torture tests (Task 13). The start block stages a
# publish, THEN raises on its first attempt only (via a class-level counter,
# standing in for the transient failure chaotic_job would otherwise inject) —
# this is the shape that would produce a "ghost cascade" (a staged publish
# surfacing despite its own block never committing) if the commit-at-end
# invariant (§A.1/§A.4) didn't hold.
class GlitchSaga < SagaForge::Base
  cattr_accessor :attempts_seen, default: 0

  correlate_by :id
  retry_policy max_attempts: 5

  start_with :g_started do |saga, _payload|
    saga.publish :g_echo, id: saga.correlation_id
    GlitchSaga.attempts_seen += 1
    raise "glitch" if GlitchSaga.attempts_seen == 1
  end

  # A middle state gives the version-race test a real "during" handler to
  # conflict over (as opposed to the create-race already covered by
  # execution_commit_test.rb).
  during :awaiting_g_echo, on: :g_advance do |saga, _payload|
    saga.context[:advanced] = true
  end

  finish_with :done
end
