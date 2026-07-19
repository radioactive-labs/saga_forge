module SagaForge
  # All engine models subclass this abstract class, so pointing it at a
  # connection moves the whole engine. Config is read once at class load —
  # safe because initializers run before models are first referenced.
  # Nothing configured → models stay on the app's primary connection.
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    if SagaForge.config.connects_to
      connects_to(**SagaForge.config.connects_to)
    elsif (db = SagaForge.config.database)
      connects_to database: {writing: db, reading: db}
    end
  end
end
