class FirstMultiSaga < SagaForge::Base
  correlate_by :id

  start_with :fm_start do |saga, _payload|
    saga.context[:started] = true
  end

  during :midway, on: :fm_go do |saga, _payload|
    saga.context[:progressed] = true
  end

  finish_with :done
end

class SecondMultiSaga < SagaForge::Base
  correlate_by :id

  start_with :sm_start do |saga, _payload|
    saga.context[:started] = true
  end

  during :midway, on: :sm_go do |saga, _payload|
    saga.transition_to :done
  end

  finish_with :done
end
