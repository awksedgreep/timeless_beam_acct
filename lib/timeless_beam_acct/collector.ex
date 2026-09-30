defmodule TimelessBeamAcct.Collector do
  @moduledoc """
  The collection loop.

  ## Ticks land on round times

  A reading is taken at each multiple of the interval on the wall clock,
  and stamped with that time. Two nodes sample at the same moments, a node
  samples at the moments its host does, and a graph bucket never splits an
  interval. Rates use the monotonic clock for the length of the interval.
  A sweep that overruns, or a host that sleeps, skips the ticks it missed
  rather than running them late.

  ## What a tick does, and in what order

  1. Takes in what the tracer heard. Everything that started is laid out
     and given its place before anything that ended is accounted: a child
     ends before its parent, and is heard of before it as often as after.
  2. Records what the VM remarked on, while the processes remarked on are
     still known.
  3. Accounts what ended.
  4. Sweeps. What the sweep finds gone, with no word of its end, is
     accounted as gone.

  The first tick is for the differences it makes possible. Its samples are
  not stored, because it does not fall on a round time; what ended before
  it is accounted all the same.

  ## A sweep may take only so much

  A sweep asks every process four things, which costs a little under a
  microsecond a process: a tenth of a second for a hundred thousand. It is
  done in this process, which the VM schedules as it does any other, so it
  does not hold the node up. But it is work the node does for the
  collector and not for whoever the node is for.

  So a sweep may take `:sweep_budget` of one scheduler: a tenth, unless
  told otherwise. A sweep that takes longer than that share of the
  interval is followed by a longer interval, in multiples of the one asked
  for, and by the one asked for again when sweeps are short again.

  ## Only so many records

  A node may end ten thousand processes a second. A record of each is a
  log that says nothing, at the cost of the store and of the node.
  `:max_records` of those that ended as they were meant to are kept from
  one tick, and as many again of those that did not. The totals count
  them all.
  """

  use GenServer

  require Logger

  alias TimelessBeamAcct.{
    Accounting,
    Batch,
    Clock,
    Collect,
    Ending,
    History,
    Identity,
    Options,
    Processes,
    Tick,
    Tracer,
    Writer
  }

  # A timer fires to the millisecond, and a tick that is due in half of
  # one is due.
  @early 0.002

  @spec start_link(Options.t()) :: GenServer.on_start()
  def start_link(%Options{} = options) do
    GenServer.start_link(__MODULE__, options, name: Options.name(options, :Collector))
  end

  @doc """
  What the collector last knew of the node and of itself: what
  `TimelessBeamAcct.status/1` and `top/1` read. `nil` if no collector of
  that name is running.
  """
  @spec status(Options.t() | atom()) :: map() | nil
  def status(name) do
    table = Options.name(name, :Status)

    for {key, value} <- :ets.tab2list(table), into: %{}, do: {key, value}
  rescue
    ArgumentError -> nil
  end

  @doc """
  Take a reading now, of everything, and wait until it has been taken.

  Its samples are stored at the time it is, which is not a round one. For
  tests, and for a person who does not want to wait ten seconds.
  """
  @spec tick(Options.t() | atom(), timeout()) :: :ok
  def tick(name, timeout \\ 30_000),
    do: GenServer.call(Options.name(name, :Collector), :tick, timeout)

  ## The process

  @impl true
  def init(%Options{} = options) do
    Process.flag(:trap_exit, true)

    tracer = Tracer.handle(options)
    options = able(options, tracer)

    state = %{
      options: options,
      tracer: tracer,
      status: :ets.new(Options.name(options, :Status), [:named_table, :set, :protected]),
      history: History.new(options),
      processes: if(options.processes, do: Processes.new(options)),
      vm: if(options.vm, do: Collect.Vm.new(options)),
      ets: if(options.ets, do: Collect.Ets.new(options)),
      dist: if(options.dist, do: Collect.Dist.new(options)),
      due: %{vm: nil, processes: nil},
      stretch: 1,
      timer: nil,
      # What the tracer had counted at the last sweep, and when that was.
      counted: nil,
      records_dropped: 0,
      ticks_dropped: 0
    }

    :ets.insert(state.status, [
      {:options, options},
      {:started, Clock.now()},
      {:exits, exits_are(options, tracer)}
    ])

    {:ok, state, {:continue, :first}}
  end

  # Spans are made of what the VM says of each exit. On a VM that has no
  # trace sessions a collector is as one told `exits: false`: what is
  # noticed gone has a record, and no span.
  defp able(options, nil), do: %{options | traces: false}
  defp able(options, _tracer), do: options

  defp exits_are(%Options{exits: false}, _tracer), do: :not_asked_for
  defp exits_are(_options, nil), do: :unavailable
  defp exits_are(_options, _tracer), do: :heard

  @impl true
  def handle_continue(:first, state) do
    started = Clock.now()

    state =
      state
      |> reading(round(started), true, true, true)
      |> due_after(Clock.now(), true, true)
      |> schedule()

    {:noreply, state}
  end

  @impl true
  def handle_info({:tick, due}, state) do
    wall = Clock.now()
    vm = due?(state.due.vm, wall)
    processes = due?(state.due.processes, wall)

    state =
      if vm or processes,
        do: reading(state, round(due), vm, processes, false),
        else: state

    # From the time it is now, not the time it was due: a sweep that
    # overran, or a host that slept, skips the ticks it missed. Until
    # then there is nothing to do, and what the tick used is given back.
    {:noreply, state |> due_after(Clock.now(), vm, processes) |> schedule(), :hibernate}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:tick, _from, state) do
    state = reading(state, round(Clock.now()), true, true, false)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    # What ended since the last sweep is accounted before closing.
    state = reading(state, round(Clock.now()), false, true, true)
    if state.vm, do: Collect.Vm.close(state.vm)
    if state.ets, do: Collect.Ets.close(state.ets)
    if state.dist, do: Collect.Dist.close(state.dist)
    :ok
  catch
    _, _ -> :ok
  end

  ## When

  defp due?(nil, _wall), do: false
  defp due?(due, wall), do: due <= wall + @early

  defp due_after(state, now, vm, processes) do
    options = state.options

    due = state.due

    due =
      if vm and options.vm,
        do: %{due | vm: Clock.next_tick(now, options.interval)},
        else: due

    due =
      if processes and options.processes,
        do: %{due | processes: Clock.next_tick(now, options.process_interval * state.stretch)},
        else: due

    %{state | due: due}
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    case [state.due.vm, state.due.processes]
         |> Enum.reject(&is_nil/1)
         |> Enum.min(fn -> nil end) do
      nil ->
        %{state | timer: nil}

      due ->
        wait = max(round((due - Clock.now()) * 1000), 0)
        %{state | timer: Process.send_after(self(), {:tick, due}, wait)}
    end
  end

  ## One reading

  # `quiet` readings are for the differences they make possible, or for
  # the exits they account: their samples are not stored.
  defp reading(state, ts, vm, processes, quiet) do
    mono = System.monotonic_time(:microsecond) / 1_000_000
    batch = Batch.new(ts)

    {state, batch} = if vm, do: read_vm(state, batch, mono), else: {state, batch}

    {state, batch, events, spans} =
      if processes and state.processes,
        do: read_processes(state, batch, mono),
        else: {state, batch, [], []}

    note_vm(state, batch, vm)

    tick = %Tick{
      metrics: if(quiet, do: Batch.clear(batch), else: batch),
      events: events,
      spans: spans
    }

    history = state.history |> History.add(events, spans) |> History.read(tick.metrics)
    state = %{state | history: history}

    cond do
      Tick.empty?(tick) -> state
      Writer.write(state.options, tick) == :ok -> state
      true -> %{state | ticks_dropped: state.ticks_dropped + 1}
    end
  end

  defp read_vm(state, batch, mono) do
    {vm, batch} =
      if state.vm, do: Collect.Vm.collect(state.vm, batch, mono), else: {nil, batch}

    {dist, batch} =
      if state.dist, do: Collect.Dist.collect(state.dist, batch, mono), else: {nil, batch}

    {%{state | vm: vm, dist: dist}, batch}
  end

  defp read_processes(state, batch, mono) do
    options = state.options
    counts = state.tracer && Tracer.counts(state.tracer)
    processes = Processes.listening(state.processes, !!(counts && counts.listening))

    {processes, ended, remarked, let_go} = take_in(state.tracer, processes, options)

    {ets, batch, by_owner} =
      if state.ets, do: Collect.Ets.collect(state.ets, batch), else: {nil, batch, %{}}

    {processes, batch, gone, found} = Processes.sweep(processes, batch, by_owner)

    {records, spans, over} = account(ended ++ gone, options)

    state = %{
      state
      | processes: processes,
        ets: ets,
        records_dropped: state.records_dropped + let_go + over
    }

    state = state |> stretch(found) |> note_sweep(found, counts)
    batch = report(batch, state, counts, mono)

    events = Enum.sort_by(records ++ remarked, & &1.ts_us)
    {%{state | counted: {counts, mono}}, batch, events, spans}
  end

  # What the tracer heard, taken a lot at a time. In each lot, everything
  # that started is given its place, then what was remarked on is
  # recorded while the processes remarked on are still known, and then
  # what ended is accounted.
  defp take_in(nil, processes, _options), do: {processes, [], [], 0}

  defp take_in(tracer, processes, options) do
    room = %{ordinary: options.max_records, failed: options.max_records}
    upto = Tracer.last(tracer)
    take_in(tracer, upto, processes, options, room, {[], [], 0})
  end

  defp take_in(tracer, upto, processes, options, room, {ended, remarked, let_go}) do
    case Tracer.take(tracer, upto) do
      [] ->
        {processes, ended, remarked, let_go}

      heard ->
        {processes, exits, remarks} = Processes.heard(processes, heard)

        remarked =
          remarks
          |> Enum.take(max(options.max_anomalies - length(remarked), 0))
          |> Enum.map(&remark(processes, &1))
          |> then(&(remarked ++ &1))

        {processes, described, room, over} = Processes.ended(processes, exits, room)
        acc = {ended ++ described, remarked, let_go + over}
        take_in(tracer, upto, processes, options, room, acc)
    end
  end

  ## Accounting

  # The records and spans of what ended. Those that were noticed gone are
  # among them, and there may be no more room for all of those either.
  defp account(ended, options) do
    ended = Enum.sort_by(ended, & &1.ended)

    {kept, _room, over} =
      Enum.reduce(ended, {[], %{ordinary: 0, failed: 0}, 0}, fn process, {kept, taken, over} ->
        kind = if Ending.ok?(process.ending) == false, do: :failed, else: :ordinary

        if taken[kind] < options.max_records,
          do: {[process | kept], %{taken | kind => taken[kind] + 1}, over},
          else: {kept, taken, over + 1}
      end)

    kept = Enum.reverse(kept)

    records =
      case options.records do
        :none -> []
        :abnormal -> Enum.filter(kept, &(Ending.ok?(&1.ending) == false))
        :all -> kept
      end

    spans = if options.traces, do: Enum.map(kept, &Accounting.span/1), else: []

    {Enum.map(records, &Accounting.exit_event(&1, options.exit_levels)),
     Enum.reject(spans, &is_nil/1), over}
  end

  defp remark(processes, {kind, subject, value, detail, at}) do
    described = describe(processes, subject)

    Accounting.remark_event(
      Map.merge(described, %{kind: kind, at: Processes.epoch_us(at), value: value, detail: detail})
    )
  end

  defp describe(processes, pid) when is_pid(pid) do
    known =
      case Processes.known(processes, pid) do
        nil ->
          # Not heard of, and not yet swept. It is asked, if it is there.
          case Identity.read(pid) do
            nil -> %{group: "unknown", name: nil, path: nil, app: nil}
            identity -> identified(identity)
          end

        known ->
          known
      end

    %{
      pid: Identity.pid_text(pid),
      group: known.group,
      name: known.name,
      path: known.path,
      app: known.app || "none"
    }
  end

  defp describe(_processes, port) when is_port(port) do
    name =
      case :erlang.port_info(port, :name) do
        {:name, name} -> List.to_string(name)
        _ -> "port"
      end

    %{pid: inspect(port), group: name, name: nil, path: nil, app: "none"}
  end

  defp describe(_processes, other),
    do: %{pid: inspect(other), group: "unknown", name: nil, path: nil, app: "none"}

  defp identified(identity) do
    %{
      group: Identity.group(identity),
      name: Identity.name(identity),
      path: Identity.path(identity),
      app: nil
    }
  end

  ## The collector's own figures

  defp report(batch, state, counts, mono) do
    batch =
      batch
      |> Batch.push("beam_acct_records_dropped", state.records_dropped)
      |> Batch.push("beam_acct_ticks_dropped", state.ticks_dropped)
      |> Batch.push("beam_acct_sweep_interval_seconds", sweep_interval(state))

    case counts do
      nil ->
        batch

      counts ->
        {spawns, exits} =
          case state.counted do
            {%{} = before, since} ->
              {Batch.rate(counts.spawns, before.spawns, mono - since),
               Batch.rate(counts.exits, before.exits, mono - since)}

            _ ->
              {nil, nil}
          end

        batch
        |> Batch.push("beam_vm_spawns_per_sec", spawns)
        |> Batch.push("beam_vm_exits_per_sec", exits)
        |> Batch.push("beam_acct_spawns", counts.spawns)
        |> Batch.push("beam_acct_exits", counts.exits)
        |> Batch.push("beam_acct_trace_listening", if(counts.listening, do: 1, else: 0))
        |> Batch.push("beam_acct_trace_suspensions", counts.suspensions)
        |> Batch.push("beam_acct_trace_waiting", counts.waiting)
        |> Batch.push("beam_acct_remarks", counts.remarks)
        |> Batch.push("beam_acct_remarks_dropped", counts.remarks_dropped)
    end
  end

  defp sweep_interval(state), do: state.options.process_interval * state.stretch

  # How many of the intervals asked for there are between two sweeps.
  defp stretch(state, found) do
    options = state.options
    allowed = options.sweep_budget * options.process_interval
    stretch = max(ceil(found.seconds / allowed), 1)

    cond do
      stretch > state.stretch ->
        Logger.warning(
          "timeless_beam_acct: a sweep of #{found.processes} processes took " <>
            "#{Float.round(found.seconds, 3)}s; sweeping every " <>
            "#{options.process_interval * stretch}s"
        )

      stretch < state.stretch and stretch == 1 ->
        Logger.info("timeless_beam_acct: sweeping every #{options.process_interval}s again")

      true ->
        :ok
    end

    %{state | stretch: stretch}
  end

  ## What is known, for those who ask

  defp note_sweep(state, found, counts) do
    :ets.insert(state.status, [
      {:sweep,
       %{
         at: Clock.now(),
         processes: found.processes,
         seconds: found.seconds,
         interval: sweep_interval(state),
         reported: Processes.admitted(state.processes)
       }},
      {:tracer, counts},
      {:dropped, %{records: state.records_dropped, ticks: state.ticks_dropped}}
    ])

    state
  end

  defp note_vm(_state, _batch, false), do: :ok

  defp note_vm(state, batch, true) do
    wanted = %{
      "beam_vm_processes" => :processes,
      "beam_vm_run_queue" => :run_queue,
      "beam_vm_mem_total_bytes" => :memory_total_bytes,
      "beam_vm_reductions_per_sec" => :reductions_per_sec,
      "beam_vm_scheduler_util_pct" => :scheduler_util_pct
    }

    vm =
      for {name, labels, value} <- batch.samples,
          key = wanted[name],
          labels in [[], [{"scheduler", "all"}]],
          into: %{},
          do: {key, value}

    if vm != %{}, do: :ets.insert(state.status, {:vm, Map.put(vm, :at, batch.ts)})
    :ok
  end
end
