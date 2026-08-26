require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
end

require "standard/rake"

task default: %i[test standard]

# Release tasks (release:core:*, release:dashboard:*). Loaded after
# bundler/gem_tasks so it can neutralize the bare `rake release` footgun.
Dir.glob(File.expand_path("lib/tasks/*.rake", __dir__)).sort.each { |f| load f }
