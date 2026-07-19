require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
end

require "standard/rake"

task default: %i[test standard]

# Neutralize bundler's `rake release` footgun (release flow comes with the
# dashboard-phase tooling; until then, releases are manual and deliberate).
Rake::Task["release"].clear if Rake::Task.task_defined?("release")
