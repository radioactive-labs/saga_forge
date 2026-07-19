# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require "minitest/autorun"
require "minitest/reporters"
Minitest::Reporters.use! [Minitest::Reporters::DefaultReporter.new(color: true)]

require "combustion"
require "action_controller/railtie"
require "saga_forge"

Combustion.path = "test/internal"
Combustion.initialize! :active_record, :active_job, :action_controller

require "saga_forge/dashboard"
require "rails/test_help"
require "rack/test"

Rails.application.eager_load!

module SagaForge
  module Dashboard
    class TestCase < ActiveSupport::TestCase
      include Rack::Test::Methods
      include ActiveJob::TestHelper

      def app = Rails.application

      setup do
        SagaForge.reset_configuration!
        SagaForge::Dashboard.reset_configuration!
        SagaForge::Dashboard.configure { |c| c.authentication = :none }
      end
    end
  end
end
