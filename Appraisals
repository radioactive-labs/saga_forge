appraise "rails-7.1" do
  gem "rails", "~> 7.1", ">= 7.1.3.4"
  # Rails 7.1's Active Record adapter predates sqlite3 2.x support; a fresh
  # resolve without this pin would drag in the same 2.x this repo's main
  # Gemfile uses for Rails 8.1, which Rails 7.1 can't boot against.
  gem "sqlite3", "~> 1.4"
end

appraise "rails-8.0" do
  gem "rails", "~> 8.0"
end

appraise "rails-8.1" do
  gem "rails", "~> 8.1"
end
