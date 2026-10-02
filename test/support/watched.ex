defmodule TimelessBeamAcct.Watched do
  @moduledoc """
  A node at a moment, for the tests of what draws one: its samples, and
  a store that holds what it is given.
  """

  alias TimelessBeamAcct.Watch.Data

  @doc "A reading of a node with three groups, two applications, and two processes."
  def samples do
    vm =
      for {name, value} <- [
            {"beam_vm_run_queue", 2.0},
            {"beam_vm_cpu_pct", 145.5},
            {"beam_vm_reductions_per_sec", 48_100.0},
            {"beam_vm_gcs_per_sec", 120.0},
            {"beam_vm_io_in_bytes_per_sec", 1536.0},
            {"beam_vm_io_out_bytes_per_sec", 0.0},
            {"beam_vm_spawns_per_sec", 25.0},
            {"beam_vm_exits_per_sec", 24.5},
            {"beam_vm_mem_total_bytes", 131.0 * 1024 * 1024},
            {"beam_vm_mem_processes_bytes", 60.0 * 1024 * 1024},
            {"beam_vm_mem_binary_bytes", 12.0 * 1024 * 1024},
            {"beam_vm_mem_ets_bytes", 8.0 * 1024 * 1024},
            {"beam_vm_processes", 512.0},
            {"beam_vm_processes_pct", 0.2},
            {"beam_vm_atoms_pct", 4.1},
            {"beam_vm_uptime_seconds", 7380.0}
          ],
          do: {name, [], value}

    schedulers =
      for {scheduler, busy} <- [{"all", 12.5}, {"1", 20.0}, {"2", 5.0}],
          do: {"beam_vm_scheduler_util_pct", [{"scheduler", scheduler}], busy}

    groups =
      for {group, work, memory, count, queue, rate, exits, failures} <- [
            {"MyApp.Repo", 40.0, 2.0e9, 1.0, 0.0, 19_000.0, 0.0, 0.0},
            {"MyApp.Worker", 12.0, 3.0e6, 50.0, 1200.0, 5_700.0, 2.5, 0.5},
            # It has a place, and nothing in it yet: no rates.
            {"New.Thing", nil, 0.0, 0.0, nil, nil, nil, nil}
          ],
          {suffix, value} <- [
            {"work_pct", work},
            {"memory_bytes", memory},
            {"processes", count},
            {"message_queue_len", queue},
            {"reductions_per_sec", rate},
            {"exits_per_sec", exits},
            {"failures_per_sec", failures}
          ],
          value != nil,
          do: {"beam_group_#{suffix}", [{"group", group}], value}

    apps =
      for {app, work, memory, count} <- [
            {"my_app", 52.0, 2.1e9, 51.0},
            {"none", 1.0, 5.0e6, 30.0}
          ],
          {suffix, value} <- [{"work_pct", work}, {"memory_bytes", memory}, {"processes", count}],
          do: {"beam_app_#{suffix}", [{"app", app}], value}

    processes =
      for {name, pid, group, app, work, memory, queue, reductions} <- [
            {"MyApp.Repo", "<0.512.0>", "MyApp.Repo", "my_app", 38.0, 1.9e9, 0.0, 9.0e6},
            {"worker_7", "<0.700.0>", "MyApp.Worker", "my_app", 1.5, 6.0e4, 1200.0, 4.0e4}
          ],
          labels = [{"proc", name <> pid}, {"pid", pid}, {"group", group}, {"app", app}],
          {suffix, value} <- [
            {"work_pct", work},
            {"memory_bytes", memory},
            {"message_queue_len", queue},
            {"reductions", reductions}
          ],
          do: {"beam_proc_#{suffix}", labels, value}

    vm ++ schedulers ++ groups ++ apps ++ processes
  end

  @doc "The node of `samples/0`, at a moment."
  def snapshot(at \\ 1_753_000_000.0), do: Data.read(at, Data.series(samples()))

  defmodule Store do
    @moduledoc """
    A store that holds what it is given, and says what it was asked.
    """

    @behaviour TimelessBeamAcct.Watch.Store

    defstruct range: nil,
              series: %{},
              history: [],
              spacing: {10.0, 10.0},
              timeline: {[], 10.0},
              incidents: [],
              exits: [],
              jobs: [],
              error: nil,
              to: nil

    defp asked(store, what), do: if(store.to, do: send(store.to, {:asked, what}))

    @impl true
    def range(store), do: {store.range, store}

    @impl true
    def at(store, at, within) do
      asked(store, {:at, at, within})
      if store.error, do: {:error, store.error}, else: {:ok, store.series}
    end

    @impl true
    def history(store, metric, key, want, from, to) do
      asked(store, {:history, metric, key, want, from, to})
      store.history
    end

    @impl true
    def spacing(store, _until), do: store.spacing

    @impl true
    def timeline(store, from, to) do
      asked(store, {:timeline, from, to})
      store.timeline
    end

    @impl true
    def incidents(store, _from, _to, _parts), do: {store.incidents, store}

    @impl true
    def exits(store, reach, wanted) do
      asked(store, {:exits, reach})
      if store.error, do: {:error, store.error}, else: {:ok, Enum.filter(store.exits, wanted)}
    end

    @impl true
    def record(store, group, pid, from),
      do: Enum.find(store.exits, &(&1.name == group and &1.pid == pid and &1.at >= from))

    @impl true
    def jobs(store, reach, _width, wanted) do
      asked(store, {:jobs, reach})
      if store.error, do: {:error, store.error}, else: {:ok, Enum.filter(store.jobs, wanted)}
    end
  end
end
