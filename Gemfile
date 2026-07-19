source "https://rubygems.org"
gemspec

gem "rake"
gem "minitest"
gem "minitest-reporters"
gem "combustion"
gem "chaotic_job"
gem "rails", ">= 7.1"
gem "sqlite3"
gem "standard"
gem "appraisal"

# Dev/test only: exercises the `if defined?(SolidQueue)` branches in the job
# classes' limits_concurrency declarations (Task 5 review deferral). Not a
# runtime dependency of the gem itself — any ActiveJob adapter works;
# Solid Queue is just the one whose DSL we conditionally opt into.
gem "solid_queue", require: false

# Only the Postgres CI lane needs this (DB_ADAPTER=postgresql) to exercise the
# publisher's ambient-transaction savepoint dedup and jsonb update_all casts.
group :postgres, optional: true do
  gem "pg"
end
