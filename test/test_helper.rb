# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require "minitest/autorun"
require "minitest/reporters"
Minitest::Reporters.use! [Minitest::Reporters::DefaultReporter.new(color: true)]

require "combustion"
Combustion.path = "test/internal"
Combustion.initialize! :active_record, :active_job do
  config.active_job.queue_adapter = :test
end

require "saga_forge"
require "rails/test_help"

Rails.application.eager_load!

module SagaForge
  class TestCase < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      SagaForge.reset_configuration!
    end
  end
end
