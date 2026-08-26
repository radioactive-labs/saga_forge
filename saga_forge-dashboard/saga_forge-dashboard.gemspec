require_relative "lib/saga_forge/dashboard/version"

Gem::Specification.new do |spec|
  spec.name = "saga_forge-dashboard"
  spec.version = SagaForge::Dashboard::VERSION
  spec.authors = ["Stefan Froelich"]
  spec.email = ["sfroelich01@gmail.com"]
  spec.summary = "A management dashboard for SagaForge sagas."
  spec.description = "Mountable Rails engine: browse saga instances, read the event ledger, view state-machine graphs, and run recovery actions."
  spec.homepage = "https://github.com/radioactive-labs/saga_forge"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.2"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/saga_forge-dashboard/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "app/**/*", "config/**/*", "MIT-LICENSE", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "saga_forge", ">= 0.1.0"
  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "actionpack", ">= 7.1"
end
