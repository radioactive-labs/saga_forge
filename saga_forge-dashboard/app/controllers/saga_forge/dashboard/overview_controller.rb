module SagaForge
  module Dashboard
    # Fleet summary. The index is a lightweight turbo-frame shell: the cheap
    # card totals render immediately, and the per-class GROUP BY (the one real
    # aggregate on this page) is isolated in its own lazy-loaded `classes`
    # frame so it never blocks the cards or the rest of the page.
    class OverviewController < BaseController
      def index
        @totals = OverviewQuery.new.totals
      end

      def classes
        @rows = OverviewQuery.new.rows
        render layout: false
      end
    end
  end
end
