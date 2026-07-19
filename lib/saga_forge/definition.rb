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
      return [] unless defined?(RubyVM::InstructionSequence)

      jumps = []
      @handlers_by_event.each_value do |h|
        extent = block_extent(h.block)
        next unless extent
        file, first_lineno, last_lineno = extent
        next unless File.exist?(file)

        lines = File.readlines(file)
        (first_lineno..last_lineno).each do |lineno|
          line = lines[lineno - 1]
          next unless line
          line.scan(/transition_to[\s(]+:(\w+)/) do |(target)|
            from = (h.state == START) ? "[*]" : h.state
            jumps << [from, target.to_sym] if declared?(target)
          end
        end
      end
      jumps.uniq
    end

    private

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
