module SagaForge
  # Immutable boot-compiled metadata for one saga class: the chain, the
  # event→state stall table, handler registry, compensation catalog.
  class Definition
    START = :__start__

    Handler = Struct.new(:state, :event, :block, :compensate, :timeout, :on_timeout, :retry_policy)

    attr_reader :klass, :handlers_by_event, :states, :terminal_states, :compensations, :start_event

    def self.compile(klass) = new(klass).freeze

    def initialize(klass)
      @klass = klass
      @handlers_by_event = {}
      @compensations = {}
      @terminal_states = []
      during_states = []
      start_decls = []

      klass.declarations.each do |d|
        case d[:kind]
        when :start
          start_decls << d
          register_handler(START, d)
        when :during
          during_states << d[:state] unless during_states.include?(d[:state])
          register_handler(d[:state], d)
        when :finish
          @terminal_states << d[:state] unless @terminal_states.include?(d[:state])
        when :compensation
          @compensations[d[:name]] = d[:block]
        end
      end

      validate_shape!(start_decls)
      @start_event = start_decls.first[:event]
      @states = during_states + @terminal_states
      @successors = build_successors(during_states)
      validate_compensations!
      validate_timeouts!
      deep_freeze!
    end

    def handler_for(event) = @handlers_by_event[event.to_sym]

    def state_for_event(event) = handler_for(event)&.state

    def events = @handlers_by_event.keys

    def events_for_state(state) = @handlers_by_event.values.select { |h| h.state == state.to_sym }.map(&:event)

    def successor_of(state) = @successors.fetch(state.to_sym)

    def terminal?(state)
      s = state.to_sym
      @terminal_states.include?(s) || %i[compensated cancelled].include?(s)
    end

    def declared?(state)
      s = state.to_sym
      @states.include?(s) || terminal?(s)
    end

    def correlate(payload, event_name)
      correlator = klass.correlator
      value = (correlator.arity == 1) ? correlator.call(payload) : correlator.call(payload, event_name)
      if value.nil?
        raise MissingCorrelationError, "#{klass} registered #{event_name.inspect} but correlate_by returned nil"
      end
      value.to_s
    end

    # handler override → class default → step_default. (Compensation blocks
    # use RetryPolicy.compensation_default — see CompensationRunner, Task 8.)
    def retry_policy_for(handler)
      override = handler.retry_policy
      policy =
        case override
        when nil then nil
        when Hash then RetryPolicy.new(**override)
        when Array then CompositeRetryPolicy.new(override)
        else override
        end
      policy || klass.default_retry_policy || RetryPolicy.step_default
    end

    def to_mermaid
      lines = ["stateDiagram-v2"]
      chain = [START] + @states.reject { |s| @terminal_states.include?(s) } + [@terminal_states.first]
      chain.each_cons(2) do |from, to|
        events_from = (from == START) ? [@start_event] : events_for_state(from)
        label = events_from.join(" / ")
        from_name = (from == START) ? "[*]" : from
        lines << "    #{from_name} --> #{to}: #{label}"
      end
      @terminal_states.each { |t| lines << "    #{t} --> [*]" }
      jump_targets.each { |(from, to)| lines << "    #{from} --> #{to}: jump" }
      lines.join("\n")
    end

    # Best-effort literal scan for `transition_to :sym` in handler blocks
    # (jumps are opaque Ruby; unresolvable ones are simply not drawn). Each
    # match is attributed to a handler only if the match's line falls within
    # that handler's EXACT block extent (via RubyVM::InstructionSequence's
    # code_location), so two sagas sharing one file never cross-attribute a
    # jump. Anything we can't precisely locate is simply not drawn — a wrong
    # edge is worse than a missing one.
    def jump_targets
      scan_handlers(/transition_to[\s(]+:(\w+)/).filter_map do |(state, captures)|
        target = captures.first
        next unless declared?(target)
        from = (state == START) ? "[*]" : state
        [from, target.to_sym]
      end.uniq
    end

    # Best-effort literal scan for `stay` / `saga.stay` inside each handler
    # block's exact extent (same scan_handlers machinery as jump_targets).
    # Returns the set of states whose handler can loop. Computed/conditional
    # stays the scan can't see are omitted, matching jump_targets' honesty.
    def stay_targets
      scan_handlers(/(?:^|[^.\w])(?:saga\.)?stay\b/).map { |(state, _match)| state }.uniq
    end

    # Structured graph (chain + jump + stay), the sibling of to_mermaid.
    def to_graph
      nodes = [SagaForge::Dashboard::Node.new(id: START.to_s, label: "start", kind: :start)]
      (@states - @terminal_states).each do |s|
        nodes << SagaForge::Dashboard::Node.new(id: s.to_s, label: s.to_s, kind: :state)
      end
      @terminal_states.each do |s|
        nodes << SagaForge::Dashboard::Node.new(id: s.to_s, label: s.to_s, kind: :terminal)
      end

      edges = []
      chain = [START] + (@states - @terminal_states) + [@terminal_states.first]
      chain.each_cons(2) do |from, to|
        label = (from == START) ? @start_event.to_s : events_for_state(from).join(" / ")
        edges << SagaForge::Dashboard::Edge.new(from: from.to_s, to: to.to_s, kind: :chain, label: label)
      end
      jump_targets.each do |(from, to)|
        from_id = (from == "[*]") ? START.to_s : from.to_s
        edges << SagaForge::Dashboard::Edge.new(from: from_id, to: to.to_s, kind: :jump, label: "jump")
      end
      stay_targets.each do |state|
        edges << SagaForge::Dashboard::Edge.new(from: state.to_s, to: state.to_s, kind: :stay, label: "stay")
      end

      SagaForge::Dashboard::Graph.new(nodes.freeze, edges.freeze).freeze
    end

    private

    # Shared block-extent scanner for jump_targets/stay_targets. Yields, for
    # every line within every handler's EXACT block extent, the handler's
    # state paired with whatever String#scan produces for that regex (the
    # full match, or its capture groups) — so two sagas sharing one file
    # never cross-attribute a match. Anything we can't precisely locate is
    # simply not scanned — a wrong edge is worse than a missing one.
    def scan_handlers(regex)
      return [] unless defined?(RubyVM::InstructionSequence)

      matches = []
      @handlers_by_event.each_value do |h|
        extent = block_extent(h.block)
        next unless extent
        file, first_lineno, last_lineno = extent
        next unless File.exist?(file)

        lines = File.readlines(file)
        (first_lineno..last_lineno).each do |lineno|
          line = lines[lineno - 1]
          next unless line
          line.scan(regex) { |m| matches << [h.state, m] }
        end
      end
      matches
    end

    # [file, first_lineno, last_lineno] for a handler's block, or nil if the
    # exact extent can't be determined (no iseq, or no code_location — older
    # Ruby / non-MRI).
    def block_extent(block)
      return nil unless block
      iseq = RubyVM::InstructionSequence.of(block)
      return nil unless iseq
      code_location = iseq.to_a[4].is_a?(Hash) ? iseq.to_a[4][:code_location] : nil
      return nil unless code_location
      first_lineno, _first_col, last_lineno, _last_col = code_location
      [iseq.path, first_lineno, last_lineno]
    rescue TypeError, ArgumentError
      nil
    end

    def register_handler(state, d)
      event = d[:event]
      if (existing = @handlers_by_event[event])
        if state == START && existing.state == START
          raise DefinitionError, "#{klass} declares start_with more than once"
        end
        raise AmbiguousEventError,
          "#{klass} registers #{event.inspect} under both #{existing.state.inspect} and #{state.inspect}"
      end
      @handlers_by_event[event] = Handler.new(
        state:, event:, block: d[:block], compensate: d[:compensate],
        timeout: d[:timeout], on_timeout: d[:on_timeout], retry_policy: d[:retry_policy]
      )
    end

    def validate_shape!(start_decls)
      raise DefinitionError, "#{klass} needs exactly one start_with (found #{start_decls.size})" unless start_decls.size == 1
      raise NoTerminalStateError, "#{klass} declares no finish_with" if @terminal_states.empty?
      raise MissingCorrelationError, "#{klass} is missing correlate_by" if klass.correlator.nil?
    end

    def build_successors(during_states)
      chain = [START] + during_states + [@terminal_states.first]
      chain.each_cons(2).to_h
    end

    def validate_compensations!
      @handlers_by_event.each_value do |h|
        next if h.compensate.nil? || @compensations.key?(h.compensate)
        raise UnknownCompensationError,
          "#{klass} handler for #{h.event.inspect} compensates with undeclared #{h.compensate.inspect}"
      end
    end

    # timeout:/on_timeout: are a pair: neither makes sense without the other.
    # A resolvable on_timeout is checked now (boot) so a typo'd or stale
    # target screams at compile time, not months later when a timer fires
    # (TimeoutJob's fire-time declared? check is belt-and-braces for state
    # removed in a later deploy while old timers are still armed).
    def validate_timeouts!
      @handlers_by_event.each_value do |h|
        if h.timeout && h.on_timeout.nil?
          raise DefinitionError,
            "#{klass} handler for #{h.event.inspect} declares timeout: without on_timeout:"
        end
        if h.on_timeout && h.timeout.nil?
          raise DefinitionError,
            "#{klass} handler for #{h.event.inspect} declares on_timeout: without timeout:"
        end
        next unless h.timeout

        target = h.on_timeout.to_sym
        next if target == :fail!
        next if declared?(target)
        raise DefinitionError,
          "#{klass} handler for #{h.event.inspect} declares on_timeout: #{h.on_timeout.inspect} — not a declared state"
      end
    end

    # Definition.compile freezes the Definition object itself, but that's
    # shallow: the memoized @definition is shared process-wide, so a stray
    # mutation of one of its collections (or a Handler struct) would
    # permanently corrupt boot metadata for every saga instance. Freeze
    # everything reachable.
    def deep_freeze!
      @handlers_by_event.each_value(&:freeze)
      @handlers_by_event.freeze
      @compensations.freeze
      @states.freeze
      @terminal_states.freeze
      @successors.freeze
    end
  end
end
