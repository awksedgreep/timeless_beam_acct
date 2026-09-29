defmodule TimelessBeamAcct.Collect.Vm do
  @moduledoc """
  The VM as a whole: what sar reports of a host, reported of a node.

  Every metric is a gauge. The VM keeps counters (reductions, bytes, time
  spent running), and a counter draws as a line that only rises, so the
  rate is taken here from two readings and the time between them. The
  first reading has nothing to take a difference against: it gives the
  levels and none of the rates.

  | metric | is |
  |---|---|
  | `beam_vm_scheduler_util_pct` | share of time the schedulers were running something. Label `scheduler`: `all`, `1`, `2`, … |
  | `beam_vm_dirty_cpu_util_pct`, `beam_vm_dirty_io_util_pct` | the same, of the dirty schedulers of each kind together |
  | `beam_vm_cpu_pct` | CPU time of all the VM's threads, as a share of **one** CPU, as top reports it: it passes 100 |
  | `beam_vm_run_queue`, `beam_vm_run_queue_dirty_cpu`, `beam_vm_run_queue_dirty_io` | processes and ports ready to run, and waiting |
  | `beam_vm_reductions_per_sec`, `beam_vm_context_switches_per_sec` | work done |
  | `beam_vm_gcs_per_sec`, `beam_vm_gc_reclaimed_bytes_per_sec` | garbage collections, and what they gave back |
  | `beam_vm_io_in_bytes_per_sec`, `beam_vm_io_out_bytes_per_sec` | bytes through ports |
  | `beam_vm_mem_<kind>_bytes` | `total`, `processes`, `processes_used`, `system`, `atom`, `atom_used`, `binary`, `code`, `ets` |
  | `beam_vm_processes`, `beam_vm_ports`, `beam_vm_atoms`, `beam_vm_ets_tables` | how many there are, and with `_pct`, the share of the limit |
  | `beam_vm_persistent_terms`, `beam_vm_persistent_term_bytes` | |
  | `beam_vm_uptime_seconds` | |
  | `beam_vm_msacc_<state>_pct` | share of the time of all the VM's threads spent in each state; only with `:msacc` |

  Scheduler modes and memory kinds are separate metrics and not a label,
  because a canvas element selects a series by host, metric, and one label.

  ## Schedulers

  A scheduler that has nothing to run spins for a while before it sleeps,
  so the CPU the operating system charges to the VM says more than the VM
  did. Scheduler utilisation is the VM's own account: the share of time a
  scheduler was running a process, a port, or a collection.

  Only schedulers that are online are reported, and `all` is over those:
  a scheduler that is offline is never busy, and would make a node with
  half its schedulers online look half idle when it is saturated.

  The VM keeps these times only while `:scheduler_wall_time` is on. The
  flag is counted for each process that turned it on, and is released when
  that process ends. So `new/1` must be called in the process that will
  call `collect/3`, and that process must be the one that lives as long as
  the collector does: a flag turned on in a process that starts the
  collector and ends would be off by the second reading.

  ## Reading without disturbing

  `statistics(:reductions)` and `statistics(:runtime)` return a total and
  a figure since the last call, by anyone. Only the total is read, and the
  previous reading is kept here. The call still moves "the last call" for
  whoever reads the second figure: the VM has no other way to ask.
  Uptime is taken from the monotonic clock and the VM's start time, which
  is the same number as `statistics(:wall_clock)` gives and moves nothing.

  ## Microstate accounting

  It is one switch for the whole VM, and it costs something on every
  change of state in every thread. It is turned on only if `:msacc` was
  asked for, and `close/1` turns it off only if it was off before.
  """

  alias TimelessBeamAcct.{Batch, Options}

  @memory_kinds [
    :total,
    :processes,
    :processes_used,
    :system,
    :atom,
    :atom_used,
    :binary,
    :code,
    :ets
  ]
  @memory_names Enum.map(@memory_kinds, &{&1, "beam_vm_mem_#{&1}_bytes"})

  @all [{"scheduler", "all"}]

  @typedoc """
  What the VM said at one instant. Counters are as the VM keeps them:
  totals since it started.

  `scheduler_wall_time` is `nil` while the flag is off, `memory` is `nil`
  on a VM that cannot say, and `msacc` is `nil` unless it was asked for.
  """
  @type reading :: %{
          schedulers: pos_integer(),
          schedulers_online: pos_integer(),
          dirty_cpu_schedulers: non_neg_integer(),
          dirty_cpu_schedulers_online: non_neg_integer(),
          scheduler_wall_time:
            [{id :: pos_integer(), active :: non_neg_integer(), total :: non_neg_integer()}] | nil,
          run_queues: [non_neg_integer()],
          runtime_ms: non_neg_integer(),
          reductions: non_neg_integer(),
          context_switches: non_neg_integer(),
          gcs: non_neg_integer(),
          gc_bytes: non_neg_integer(),
          io_in_bytes: non_neg_integer(),
          io_out_bytes: non_neg_integer(),
          memory: keyword(non_neg_integer()) | nil,
          processes: {count :: non_neg_integer(), limit :: pos_integer()},
          ports: {count :: non_neg_integer(), limit :: pos_integer()},
          atoms: {count :: non_neg_integer(), limit :: pos_integer()},
          ets_tables: {count :: non_neg_integer(), limit :: pos_integer()},
          persistent_terms: non_neg_integer(),
          persistent_term_bytes: non_neg_integer(),
          uptime_ms: non_neg_integer(),
          msacc: %{atom() => non_neg_integer()} | nil
        }

  @type state :: %__MODULE__{
          per_scheduler: boolean(),
          msacc: boolean(),
          msacc_was_on: boolean(),
          previous: reading() | nil,
          at: float() | nil
        }

  defstruct per_scheduler: true, msacc: false, msacc_was_on: false, previous: nil, at: nil

  @doc """
  Turn on what the VM must be keeping, and remember what was on already.

  Call it in the process that will call `collect/3`: the VM keeps scheduler
  times for as long as a process that asked for them lives.
  """
  @spec new(Options.t()) :: state()
  def new(%Options{} = options) do
    :erlang.system_flag(:scheduler_wall_time, true)

    {msacc, was_on} =
      if options.msacc do
        try do
          {true, :erlang.system_flag(:microstate_accounting, true) == true}
        rescue
          # A VM built without it.
          ArgumentError -> {false, false}
        end
      else
        {false, false}
      end

    %__MODULE__{per_scheduler: options.per_scheduler, msacc: msacc, msacc_was_on: was_on}
  end

  @doc """
  Read the VM, and add this instant's samples to the batch.

  `mono` is monotonic time in seconds. Rates are over the time since the
  call before this one.
  """
  @spec collect(state(), Batch.t(), float()) :: {state(), Batch.t()}
  def collect(%__MODULE__{} = state, %Batch{} = batch, mono) when is_number(mono) do
    reading = read(state.msacc)
    seconds = if state.at, do: mono - state.at

    batch =
      report(batch, state.previous, reading, seconds, per_scheduler: state.per_scheduler)

    {%{state | previous: reading, at: mono}, batch}
  end

  @doc """
  Give back what `new/1` took: this process's hold on scheduler times, and
  microstate accounting if this collector was what turned it on.

  Call it in the process that called `new/1`.
  """
  @spec close(state()) :: :ok
  def close(%__MODULE__{} = state) do
    :erlang.system_flag(:scheduler_wall_time, false)

    if state.msacc and not state.msacc_was_on do
      :erlang.system_flag(:microstate_accounting, false)
    end

    :ok
  end

  @doc """
  The samples of one reading, and of the difference between it and the one
  before.

  With no reading before, or no time between them, only the levels are
  given. `seconds` is the time between the two readings.

  Options: `:per_scheduler` (default `true`), whether each scheduler is
  reported as well as all of them together.
  """
  @spec report(Batch.t(), reading() | nil, reading(), number() | nil, keyword()) :: Batch.t()
  def report(%Batch{} = batch, previous, reading, seconds, opts \\ []) do
    batch = levels(batch, reading)

    if is_map(previous) and is_number(seconds) and seconds > 0 do
      batch
      |> schedulers(previous, reading, Keyword.get(opts, :per_scheduler, true))
      |> activity(previous, reading, seconds)
      |> msacc(previous, reading)
    else
      batch
    end
  end

  # ---- reading ----

  @doc false
  @spec read(boolean()) :: reading()
  def read(msacc? \\ false) do
    {gcs, gc_words, _} = :erlang.statistics(:garbage_collection)
    {{:input, io_in}, {:output, io_out}} = :erlang.statistics(:io)
    {reductions, _since} = :erlang.statistics(:reductions)
    {runtime_ms, _since} = :erlang.statistics(:runtime)
    {context_switches, _} = :erlang.statistics(:context_switches)
    terms = :persistent_term.info()

    %{
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      dirty_cpu_schedulers: info(:dirty_cpu_schedulers, 0),
      dirty_cpu_schedulers_online: info(:dirty_cpu_schedulers_online, 0),
      scheduler_wall_time: scheduler_wall_time(),
      run_queues: :erlang.statistics(:run_queue_lengths_all),
      runtime_ms: runtime_ms,
      reductions: reductions,
      context_switches: context_switches,
      gcs: gcs,
      gc_bytes: gc_words * :erlang.system_info(:wordsize),
      io_in_bytes: io_in,
      io_out_bytes: io_out,
      memory: memory(),
      processes: {:erlang.system_info(:process_count), :erlang.system_info(:process_limit)},
      ports: {:erlang.system_info(:port_count), :erlang.system_info(:port_limit)},
      atoms: {:erlang.system_info(:atom_count), :erlang.system_info(:atom_limit)},
      ets_tables: {:erlang.system_info(:ets_count), :erlang.system_info(:ets_limit)},
      persistent_terms: terms.count,
      persistent_term_bytes: terms.memory,
      uptime_ms: uptime_ms(),
      msacc: if(msacc?, do: microstates())
    }
  end

  defp info(key, otherwise) do
    :erlang.system_info(key)
  rescue
    ArgumentError -> otherwise
  end

  # `:undefined` until the flag is on.
  defp scheduler_wall_time do
    case :erlang.statistics(:scheduler_wall_time_all) do
      times when is_list(times) -> times
      _ -> nil
    end
  end

  # A VM started with some of its allocators disabled cannot add its
  # memory up, and says so by raising.
  defp memory do
    :erlang.memory()
  rescue
    _ -> nil
  end

  defp uptime_ms do
    System.convert_time_unit(
      :erlang.monotonic_time() - :erlang.system_info(:start_time),
      :native,
      :millisecond
    )
  end

  # Each thread's time in each state, added up over the threads.
  defp microstates do
    case :erlang.statistics(:microstate_accounting) do
      threads when is_list(threads) ->
        Enum.reduce(threads, %{}, fn %{counters: counters}, sums ->
          Map.merge(sums, counters, fn _state, sum, counter -> sum + counter end)
        end)

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  # ---- reporting ----

  # Gauges that need no previous reading.
  defp levels(batch, reading) do
    {normal, dirty_cpu, dirty_io} = run_queues(reading.run_queues)

    batch
    |> Batch.push("beam_vm_run_queue", normal)
    |> Batch.push("beam_vm_run_queue_dirty_cpu", dirty_cpu)
    |> Batch.push("beam_vm_run_queue_dirty_io", dirty_io)
    |> memory(reading.memory)
    |> limited("beam_vm_processes", reading.processes)
    |> limited("beam_vm_ports", reading.ports)
    |> limited("beam_vm_atoms", reading.atoms)
    |> limited("beam_vm_ets_tables", reading.ets_tables)
    |> Batch.push("beam_vm_persistent_terms", reading.persistent_terms)
    |> Batch.push("beam_vm_persistent_term_bytes", reading.persistent_term_bytes)
    |> Batch.push("beam_vm_uptime_seconds", reading.uptime_ms / 1000)
  end

  # One queue for each normal scheduler, then the dirty CPU queue, then
  # the dirty I/O queue.
  defp run_queues(queues) when is_list(queues) and length(queues) >= 2 do
    {normal, [dirty_cpu, dirty_io]} = Enum.split(queues, -2)
    {Enum.sum(normal), dirty_cpu, dirty_io}
  end

  defp run_queues(queues) when is_list(queues), do: {Enum.sum(queues), nil, nil}
  defp run_queues(_), do: {nil, nil, nil}

  defp memory(batch, nil), do: batch

  defp memory(batch, memory) do
    Enum.reduce(@memory_names, batch, fn {kind, name}, batch ->
      Batch.push(batch, name, Keyword.get(memory, kind))
    end)
  end

  defp limited(batch, name, {count, limit}) do
    batch
    |> Batch.push(name, count)
    |> Batch.push(name <> "_pct", Batch.pct(count, limit))
  end

  defp schedulers(batch, previous, reading, per_scheduler) do
    case {previous.scheduler_wall_time, reading.scheduler_wall_time} do
      {before, now} when is_list(before) and is_list(now) ->
        {normal, dirty_cpu, dirty_io} = spent(before, now, reading)

        batch
        |> Batch.push("beam_vm_scheduler_util_pct", @all, together(normal))
        |> each_scheduler(normal, per_scheduler)
        |> Batch.push("beam_vm_dirty_cpu_util_pct", together(dirty_cpu))
        |> Batch.push("beam_vm_dirty_io_util_pct", together(dirty_io))

      _not_kept ->
        batch
    end
  end

  # `{id, active, total}` over the interval, of the schedulers of each
  # kind that are online.
  #
  # The normal schedulers are numbered from 1, the dirty CPU schedulers
  # follow them, and the dirty I/O schedulers follow those. Of each kind,
  # the ones online are the first.
  defp spent(before, now, reading) do
    before = Map.new(before, fn {id, active, total} -> {id, {active, total}} end)
    normal_online = reading.schedulers_online
    normal_last = reading.schedulers
    dirty_cpu_online = normal_last + reading.dirty_cpu_schedulers_online
    dirty_cpu_last = normal_last + reading.dirty_cpu_schedulers

    Enum.reduce(now, {[], [], []}, fn {id, active, total},
                                      {normal, dirty_cpu, dirty_io} = kinds ->
      case before do
        %{^id => {active_before, total_before}}
        when active >= active_before and total >= total_before ->
          spent = {id, active - active_before, total - total_before}

          cond do
            id <= normal_online -> {[spent | normal], dirty_cpu, dirty_io}
            id <= normal_last -> kinds
            id <= dirty_cpu_online -> {normal, [spent | dirty_cpu], dirty_io}
            id <= dirty_cpu_last -> kinds
            true -> {normal, dirty_cpu, [spent | dirty_io]}
          end

        # Not in the reading before; or its times went backwards, which
        # they do when the flag is turned off and on again.
        %{} ->
          kinds
      end
    end)
  end

  defp each_scheduler(batch, _normals, false), do: batch

  defp each_scheduler(batch, normals, true) do
    normals
    |> Enum.sort()
    |> Enum.reduce(batch, fn {id, active, total}, batch ->
      labels = [{"scheduler", Integer.to_string(id)}]
      Batch.push(batch, "beam_vm_scheduler_util_pct", labels, Batch.pct(active, total))
    end)
  end

  defp together(spent) do
    {active, total} =
      Enum.reduce(spent, {0, 0}, fn {_id, active, total}, {actives, totals} ->
        {actives + active, totals + total}
      end)

    Batch.pct(active, total)
  end

  defp activity(batch, previous, reading, seconds) do
    rate = fn key -> Batch.rate(Map.fetch!(reading, key), Map.fetch!(previous, key), seconds) end

    # Milliseconds of CPU in each second, as a percentage of a second.
    cpu =
      case rate.(:runtime_ms) do
        nil -> nil
        ms_per_second -> ms_per_second / 10
      end

    batch
    |> Batch.push("beam_vm_cpu_pct", cpu)
    |> Batch.push("beam_vm_reductions_per_sec", rate.(:reductions))
    |> Batch.push("beam_vm_context_switches_per_sec", rate.(:context_switches))
    |> Batch.push("beam_vm_gcs_per_sec", rate.(:gcs))
    |> Batch.push("beam_vm_gc_reclaimed_bytes_per_sec", rate.(:gc_bytes))
    |> Batch.push("beam_vm_io_in_bytes_per_sec", rate.(:io_in_bytes))
    |> Batch.push("beam_vm_io_out_bytes_per_sec", rate.(:io_out_bytes))
  end

  defp msacc(batch, %{msacc: before}, %{msacc: now}) when is_map(before) and is_map(now) do
    spent =
      for {state, counter} <- now, is_map_key(before, state) do
        {state, counter - Map.fetch!(before, state)}
      end

    # The counters were reset if any of them went backwards, and then none
    # of the differences is over the whole interval.
    if Enum.all?(spent, fn {_state, time} -> time >= 0 end) do
      whole = spent |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      spent
      |> Enum.sort()
      |> Enum.reduce(batch, fn {state, time}, batch ->
        Batch.push(batch, "beam_vm_msacc_#{state}_pct", Batch.pct(time, whole))
      end)
    else
      batch
    end
  end

  defp msacc(batch, _previous, _reading), do: batch
end
