module SagaForge
  module Dashboard
    module DashboardHelper
      # Rails mixes these into real views automatically, so content_tag and
      # time_ago_in_words are already available there, but the helper unit
      # test includes this module directly into a plain test object, so
      # they're pulled in explicitly here to work standalone too.
      include ActionView::Helpers::TagHelper
      include ActionView::Helpers::DateHelper

      STATE_COLORS = {
        "compensating" => "amber", "compensated" => "slate",
        "cancelled" => "slate"
      }.freeze

      def state_badge(state)
        color = STATE_COLORS[state.to_s] || (terminal_like?(state) ? "green" : "indigo")
        content_tag(:span, state, class: "sf-badge sf-badge-#{color}")
      end

      def status_badge(status)
        color = {"pending" => "slate", "processed" => "green", "stalled" => "amber", "failed" => "red"}[status.to_s] || "slate"
        content_tag(:span, status, class: "sf-badge sf-badge-#{color}")
      end

      def terminal_like?(state) = %w[completed done finished shipped notified].include?(state.to_s)

      def bar_width_class(pct) = "sf-bar-#{pct.to_i.clamp(0, 100)}"

      def format_bytes(n)
        return "0 B" if n.to_i <= 0
        units = %w[B KB MB]
        e = [Math.log(n, 1024).floor, units.size - 1].min
        "#{(n.to_f / (1024**e)).round(1)} #{units[e]}"
      end

      def poll_interval
        cookies[:sf_poll_interval].presence&.to_i || SagaForge::Dashboard.config.polling_interval
      end

      # Rendered relative ("3 minutes ago") or absolute (UTC) per the viewer's
      # sf_time_format cookie preference, with the other form available on
      # hover. This is decided server-side at render time; there's no
      # client-side relative-time JS; the toggle button (dashboard.js) just
      # writes the cookie and does a Turbo reload, which re-renders every
      # time_tag on the page with the new preference.
      def time_tag(t)
        return "" unless t
        absolute = t.utc.strftime("%Y-%m-%d %H:%M:%S UTC")
        relative = "#{time_ago_in_words(t)} ago"
        shown = absolute_time? ? absolute : relative
        title = absolute_time? ? relative : absolute
        content_tag(:time, shown, datetime: t.iso8601, class: "sf-time", title: title)
      end

      # --- Layout-support helpers (not in the acceptance-criteria list above,
      # but needed by the shared layout chrome: the poll-interval <select>, the
      # relative/absolute time toggle, and the polling opt-out). ---------------

      # Auto-refresh interval options (seconds; 0 = off), from config.
      def poll_options = SagaForge::Dashboard.config.polling_interval_options

      def poll_label(secs)
        return "off" if secs.zero?
        (secs % 60 == 0) ? "#{secs / 60}m" : "#{secs}s"
      end

      # Whether the main region opts into auto-refresh. A page sets
      # @sf_disable_polling to opt OUT (e.g. the definition graph, whose live
      # Cytoscape canvas can't survive the poll's morph region refresh).
      def poll_region? = !@sf_disable_polling

      # Whether the viewer prefers absolute timestamps (cookie-persisted nav toggle).
      def absolute_time? = cookies[:sf_time_format] == "absolute"
    end
  end
end
