defmodule TimelessBeamAcct.Watch.Data do
  @moduledoc """
  What is on the screen: the node at one moment.

  A moment is read from one of two places. Now is what the collector in
  the node last read. Any other moment is read from the store. Both are
  samples under the same names, and both are turned into the same
  snapshot here, so what is watched as it happens and what is gone back
  to are the same figures.
  """

  @typedoc "The series of each metric at a moment: each one's labels, and its value."
  @type series :: %{String.t() => [{%{String.t() => String.t()}, number()}]}

  @type group :: %{
          name: String.t(),
          work: number() | nil,
          memory: number() | nil,
          processes: number() | nil,
          queue: number() | nil,
          reductions: number() | nil,
          exits: number() | nil,
          failures: number() | nil
        }

  @type process :: %{
          name: String.t(),
          proc: String.t(),
          pid: String.t(),
          group: String.t(),
          app: String.t(),
          work: number() | nil,
          memory: number() | nil,
          queue: number() | nil,
          reductions: number() | nil
        }

  @type t :: %__MODULE__{
          at: number(),
          vm: %{atom() => number()},
          groups: [group()],
          apps: [group()],
          processes: [process()]
        }

  defstruct at: 0.0, vm: %{}, groups: [], apps: [], processes: []

  # What is said of the node, and the series it is read from.
  @vm [
    run_queue: "beam_vm_run_queue",
    dirty_cpu_queue: "beam_vm_run_queue_dirty_cpu",
    dirty_io_queue: "beam_vm_run_queue_dirty_io",
    dirty_cpu: "beam_vm_dirty_cpu_util_pct",
    dirty_io: "beam_vm_dirty_io_util_pct",
    cpu: "beam_vm_cpu_pct",
    reductions: "beam_vm_reductions_per_sec",
    gcs: "beam_vm_gcs_per_sec",
    io_in: "beam_vm_io_in_bytes_per_sec",
    io_out: "beam_vm_io_out_bytes_per_sec",
    spawns: "beam_vm_spawns_per_sec",
    exits: "beam_vm_exits_per_sec",
    memory: "beam_vm_mem_total_bytes",
    memory_processes: "beam_vm_mem_processes_bytes",
    memory_binary: "beam_vm_mem_binary_bytes",
    memory_ets: "beam_vm_mem_ets_bytes",
    processes: "beam_vm_processes",
    processes_pct: "beam_vm_processes_pct",
    ports: "beam_vm_ports",
    atoms_pct: "beam_vm_atoms_pct",
    uptime: "beam_vm_uptime_seconds"
  ]

  @group_suffixes ~w(processes work_pct memory_bytes message_queue_len reductions_per_sec exits_per_sec failures_per_sec)
  @proc_suffixes ~w(memory_bytes work_pct message_queue_len reductions)

  @doc """
  Every metric a moment is read from: what to ask a store for.
  """
  @spec metrics() :: [String.t()]
  def metrics do
    Keyword.values(@vm) ++
      ["beam_vm_scheduler_util_pct"] ++
      for(
        prefix <- ["beam_group", "beam_app"],
        suffix <- @group_suffixes,
        do: "#{prefix}_#{suffix}"
      ) ++
      for(suffix <- @proc_suffixes, do: "beam_proc_#{suffix}")
  end

  @doc """
  Samples, as the series of each metric. A sample is
  `{metric, labels, value}`, its labels a list of pairs or a map. The
  host and the node are not labels that tell one series from another
  here, and are left out.
  """
  @spec series(Enumerable.t()) :: series()
  def series(samples) do
    Enum.group_by(
      samples,
      &elem(&1, 0),
      fn {_name, labels, value} -> {labels |> Map.new() |> Map.drop(["host", "node"]), value} end
    )
  end

  @doc """
  The node at a moment, from the samples of it.

  `processes` are those of the moment if they are known some other way
  than by their series: every process the collector has, where only some
  have series.
  """
  @spec read(number(), series(), [process()] | nil) :: t()
  def read(at, series, processes \\ nil) do
    vm =
      for {key, metric} <- @vm, value = only(series, metric), into: %{}, do: {key, value}

    vm =
      case labelled(series, "beam_vm_scheduler_util_pct", "scheduler", "all") do
        nil -> vm
        busy -> Map.put(vm, :schedulers, busy)
      end

    %__MODULE__{
      at: at,
      vm: vm,
      groups: groups(series, "beam_group", "group"),
      apps: groups(series, "beam_app", "app"),
      processes: processes || processes(series)
    }
  end

  @doc """
  Whether the moment has anything in it. A moment before the store began,
  or one while the collector was stopped, has not.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{vm: vm, groups: groups, processes: processes}),
    do: vm == %{} and groups == [] and processes == []

  # A group is there if it has a count of processes, which it has at
  # every reading; its rates come a reading later.
  defp groups(series, prefix, key) do
    by = fn what -> by(series, "#{prefix}_#{what}", key) end

    {counts, work, memory, queue, reductions, exits, failures} =
      {by.("processes"), by.("work_pct"), by.("memory_bytes"), by.("message_queue_len"),
       by.("reductions_per_sec"), by.("exits_per_sec"), by.("failures_per_sec")}

    for name <- counts |> Map.keys() |> Enum.concat(Map.keys(work)) |> Enum.uniq() |> Enum.sort() do
      %{
        name: name,
        work: work[name],
        memory: memory[name],
        processes: counts[name],
        queue: queue[name],
        reductions: reductions[name],
        exits: exits[name],
        failures: failures[name]
      }
    end
  end

  # A process with series has its memory at every reading, and its rates
  # a reading later.
  defp processes(series) do
    work = by(series, "beam_proc_work_pct", "proc")
    queue = by(series, "beam_proc_message_queue_len", "proc")
    reductions = by(series, "beam_proc_reductions", "proc")

    series
    |> Map.get("beam_proc_memory_bytes", [])
    |> Enum.flat_map(fn
      {%{"proc" => proc} = labels, memory} ->
        pid = labels["pid"] || ""

        [
          %{
            name: String.replace_suffix(proc, pid, ""),
            proc: proc,
            pid: pid,
            group: labels["group"] || "",
            app: labels["app"] || "",
            work: work[proc],
            memory: memory,
            queue: queue[proc],
            reductions: reductions[proc]
          }
        ]

      _ ->
        []
    end)
    |> Enum.sort_by(& &1.proc)
  end

  @doc """
  The processes a collector has, as `TimelessBeamAcct.snapshot/1` gives
  them, as the processes of a moment.
  """
  @spec from_snapshot([map()]) :: [process()]
  def from_snapshot(processes) do
    processes
    |> Enum.map(fn process ->
      name = process[:name] || process[:group] || "unknown"
      pid = process[:pid] || ""

      %{
        name: name,
        proc: name <> pid,
        pid: pid,
        group: process[:group] || "",
        app: process[:app] || "",
        work: process[:work_pct],
        memory: process[:memory_bytes],
        queue: process[:message_queue_len],
        reductions: process[:reductions]
      }
    end)
    |> Enum.sort_by(& &1.proc)
  end

  # The one series of a metric that no label tells from another.
  defp only(series, metric) do
    series
    |> Map.get(metric, [])
    |> Enum.find_value(fn {labels, value} -> if labels == %{}, do: value end)
  end

  defp labelled(series, metric, key, want) do
    series
    |> Map.get(metric, [])
    |> Enum.find_value(fn {labels, value} -> if labels[key] == want, do: value end)
  end

  # Each series of a metric, by the value of one of its labels.
  defp by(series, metric, key) do
    for {%{^key => name}, value} <- Map.get(series, metric, []), into: %{}, do: {name, value}
  end
end
