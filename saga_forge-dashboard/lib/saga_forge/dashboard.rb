require "saga_forge"
require "saga_forge/dashboard/version"
require "saga_forge/dashboard/configuration"
require "saga_forge/dashboard/engine"

module SagaForge
  module Dashboard
    ASSET_ROOT = "app/assets/saga_forge/dashboard"

    class << self
      def config = (@config ||= Configuration.new)

      def configure = yield(config)

      def reset_configuration! = @config = Configuration.new

      # Short content digest of a shipped asset, to cache-bust the served CSS/JS
      # despite the immutable cache header. Memoized once per boot.
      def asset_digest(file)
        @asset_digests ||= {}
        @asset_digests[file] ||= begin
          require "digest"
          Digest::SHA256.file(Engine.root.join(ASSET_ROOT, file)).hexdigest[0, 12]
        rescue Errno::ENOENT
          VERSION
        rescue => e
          Rails.logger.warn { "[saga_forge-dashboard] asset_digest(#{file}) failed: #{e.class}: #{e.message}" } if defined?(Rails) && Rails.logger
          VERSION
        end
      end
    end
  end
end
