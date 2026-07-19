# Recipient fixture for GlitchSaga's staged `:g_echo` publish (Task 13). Its
# only job is to exist as a registered recipient so durability_test.rb can
# assert on how many `g_echo` rows land in the ledger.
class GlitchEchoSaga < SagaForge::Base
  correlate_by :id

  start_with(:g_echo) { |saga, _payload| saga.context[:echoed] = true }

  finish_with :g_echo_done
end
