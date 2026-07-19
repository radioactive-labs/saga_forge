module SagaForge
  module Dashboard
    class AuthenticationNotConfigured < StandardError
      MESSAGE = <<~MSG.freeze
        SagaForge::Dashboard has no authentication configured. Do one of:
          - SagaForge::Dashboard.configure { |c| c.http_basic = { username:, password: } }
          - SagaForge::Dashboard.configure { |c| c.authenticate { |controller| ... } }
          - SagaForge::Dashboard.configure { |c| c.authentication = :none }  # then guard the mount yourself
      MSG
      def initialize(msg = MESSAGE) = super
    end

    class Configuration
      attr_accessor :http_basic, :authentication
      attr_reader :auth_hook
      attr_accessor :polling_interval, :polling_interval_options, :page_size

      def initialize
        @http_basic = nil
        @authentication = nil
        @auth_hook = nil
        @polling_interval = 15
        @polling_interval_options = [0, 5, 10, 15, 30, 60, 300]
        @page_size = 50
      end

      def authenticate(&block) = @auth_hook = block
    end
  end
end
