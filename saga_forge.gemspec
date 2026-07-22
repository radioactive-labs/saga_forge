require_relative "lib/saga_forge/version"

Gem::Specification.new do |spec|
  spec.name = "saga_forge"
  spec.version = SagaForge::VERSION
  spec.authors = ["Stefan Froelich"]
  spec.email = ["sfroelich01@gmail.com"]
  spec.summary = "Sagas for Rails on ActiveJob: one file, one ledger, commit-at-end atomicity, LIFO compensation."
  spec.description = "MassTransit's state machine, ChronoForge's spirit. Event-driven sagas with durable event ledger, stalling/parking, staged publishes, and derived compensation."
  spec.homepage = "https://github.com/radioactive-labs/saga_forge"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == File.basename(__FILE__)) ||
        f.start_with?("bin/", "test/", "spec/", "features/", ".git", ".github", "appraisal", "Appraisals", "gemfiles/", "docs/", "site/", "saga_forge-dashboard/", "Gemfile", "Rakefile", ".standard.yml")
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "activejob", ">= 7.1"
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "zeitwerk"
end
