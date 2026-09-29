defmodule TimelessBeamAcct.ProcessesTest do
  # Not with the others: a sweep is of every process of the node, and the
  # processes of other tests come and go.
  use ExUnit.Case, async: false

  import TimelessBeamAcct.Samples

  alias TimelessBeamAcct.{Batch, Ended, Ending, Identity, Options, Processes}

  defmodule Worker do
    use GenServer
    def init(arg), do: {:ok, arg}
    def handle_call({:work, n}, _from, state), do: {:reply, Enum.reduce(1..n, 0, &+/2), state}

    def handle_call({:hold, bytes}, _from, _state),
      do: {:reply, :ok, :binary.copy(<<0>>, bytes) |> :binary.bin_to_list()}
  end

  defp new(given \\ []) do
    name = :"processes_test_#{System.unique_integer([:positive])}"
    Processes.new(Options.new!([name: name, sink: :stdout, min_age: 0] ++ given))
  end

  defp sweep(state, by_owner \\ %{}) do
    {state, batch, vanished, found} = Processes.sweep(state, Batch.new(0), by_owner)
    # Of those that are gone, only the test's own: the test runner's
    # processes end when they please.
    mine = Process.get(:mine, [])
    {state, batch, Enum.filter(vanished, &(&1.pid in mine)), found}
  end

  defp worker(opts \\ []) do
    {:ok, pid} = GenServer.start_link(Worker, :arg, opts)
    Process.put(:mine, [Identity.pid_text(pid) | Process.get(:mine, [])])
    pid
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp born(pid, parent, at \\ :erlang.monotonic_time()) do
    identity = Identity.read(pid)
    {0, :born, at, pid, {parent, %Identity{call: identity.call, name: identity.name}}}
  end

  defp exited(pid, reason), do: {0, :exit, :erlang.monotonic_time(), pid, Ending.of(reason)}

  defp stop(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
  end

  @group "TimelessBeamAcct.ProcessesTest.Worker"

  describe "a sweep" do
    test "the first reports what needs no difference, and no rates" do
      pid = worker()
      {_state, batch, [], found} = sweep(new())

      assert found.processes > 10
      assert value(batch, "beam_acct_processes") == found.processes
      assert value(batch, "beam_group_processes", group: @group) >= 1
      assert value(batch, "beam_group_memory_bytes", group: @group) > 0
      assert value(batch, "beam_group_reductions_per_sec", group: @group) == nil
      assert value(batch, "beam_group_work_pct", group: @group) == nil
      assert value(batch, "beam_acct_reductions_accounted_pct") == nil
      assert value(batch, "beam_acct_sweep_seconds") >= 0
      GenServer.stop(pid)
    end

    test "the second reports what each group did in between" do
      pid = worker()
      idle = worker(name: unique(:idle_worker))
      {state, _, _, _} = sweep(new())

      GenServer.call(pid, {:work, 2_000_000})
      {_state, batch, [], _} = sweep(state)

      busy = value(batch, "beam_group_reductions_per_sec", group: @group)
      assert busy > 1000
      assert value(batch, "beam_group_reductions_per_sec", group: "idle_worker") < busy
      assert value(batch, "beam_group_work_pct", group: @group) > 0
      assert value(batch, "beam_group_work_pct", group: @group) <= 100

      accounted = value(batch, "beam_acct_reductions_accounted_pct")
      assert accounted > 0 and accounted <= 100

      GenServer.stop(pid)
      GenServer.stop(idle)
    end

    test "a process that was not there before was started since, and all it used is counted" do
      {state, _, _, _} = sweep(new())

      name = unique(:late_worker)
      pid = worker(name: name)
      GenServer.call(pid, {:work, 1_000_000})
      {:reductions, used} = Process.info(pid, :reductions)

      {_state, batch, [], _} = sweep(state)
      rate = value(batch, "beam_group_reductions_per_sec", group: "late_worker")
      seconds = value(batch, "beam_acct_sweep_seconds")

      # Its rate is over the whole interval, and the interval was short.
      assert rate > 0
      assert is_float(seconds)
      assert used > 1000
      GenServer.stop(pid)
    end

    test "processes are counted by the application they run in" do
      {_state, batch, _, _} = sweep(new())
      assert value(batch, "beam_app_processes", app: "kernel") > 5
      assert value(batch, "beam_app_memory_bytes", app: "kernel") > 0
      # The ones that belong to no application: the VM's own.
      assert value(batch, "beam_app_processes", app: "none") > 0
    end

    test "the memory of a table is charged to the application of its owner" do
      owner = Process.whereis(:kernel_sup)
      {_state, batch, _, _} = sweep(new(), %{owner => 4096, self() => 100})
      assert value(batch, "beam_app_ets_bytes", app: "kernel") == 4096
      assert value(batch, "beam_app_ets_bytes", app: "none") >= 100
    end

    test "instances are counted together, under what they are instances of" do
      pool = "pool#{System.unique_integer([:positive])}member"
      pids = for n <- 1..3, do: worker(name: :"#{pool}_#{n}")

      {_state, batch, _, _} = sweep(new())

      assert value(batch, "beam_group_processes", group: pool) == 3
      Enum.each(pids, &GenServer.stop/1)
    end

    test "only so many groups are reported by name, and the rest together" do
      state = new(max_groups: 3)
      {state, batch, _, found} = sweep(state)

      groups = labelled(batch, "beam_group_processes", :group)
      assert length(groups) == 4
      assert "other" in groups

      total = groups |> Enum.map(&value(batch, "beam_group_processes", group: &1)) |> Enum.sum()
      assert total == found.processes

      # Those that have a place keep it.
      {_state, again, _, _} = sweep(state)
      assert Enum.sort(labelled(again, "beam_group_processes", :group)) == Enum.sort(groups)
    end

    test "a group that has emptied is reported as nothing, until it loses its place" do
      name = unique(:emptied_pool)
      pid = worker(name: name)
      {state, batch, _, _} = sweep(new())
      assert value(batch, "beam_group_processes", group: "emptied_pool") == 1
      stop(pid)

      # Its last sample would otherwise say it is as full as it last was.
      # The first of these sweeps finds it gone, which is something of
      # it; it is absent from the next, and waited for for six.
      {state, reported} =
        Enum.reduce(1..8, {state, []}, fn _, {state, reported} ->
          {state, batch, _, _} = sweep(state)
          {state, [batch | reported]}
        end)

      [last | earlier] = reported

      for batch <- earlier do
        assert value(batch, "beam_group_processes", group: "emptied_pool") == 0
        assert value(batch, "beam_group_memory_bytes", group: "emptied_pool") == 0
        assert value(batch, "beam_group_reductions_per_sec", group: "emptied_pool") == 0
      end

      assert all(last, "beam_group_processes", group: "emptied_pool") == []
      {_state, batch, _, _} = sweep(state)
      assert all(batch, "beam_group_processes", group: "emptied_pool") == []
    end

    test "once there has been an other, there is one at every reading" do
      {_state, batch, _, _} = sweep(new(max_groups: 1_000))
      assert all(batch, "beam_group_processes", group: "other") == []

      state = new(max_groups: 3)
      {state, batch, _, _} = sweep(state)
      assert value(batch, "beam_group_processes", group: "other") > 0
      {_state, batch, _, _} = sweep(state)
      assert value(batch, "beam_group_processes", group: "other") > 0
    end

    test "an application that has stopped is reported as nothing" do
      state = new()
      owner = spawn(fn -> receive(do: (:stop -> :ok)) end)
      {state, batch, _, _} = sweep(state, %{Process.whereis(:kernel_sup) => 4096})
      assert value(batch, "beam_app_ets_bytes", app: "kernel") == 4096

      # Nothing of it is left but its name: the tables are gone.
      {_state, batch, _, _} = sweep(state, %{})
      assert value(batch, "beam_app_ets_bytes", app: "kernel") == 0
      assert value(batch, "beam_app_processes", app: "kernel") > 0
      send(owner, :stop)
    end

    test "a queue that is long is seen in its group" do
      pid = spawn_link(fn -> receive(do: (:never -> :ok)) end)
      for _ <- 1..50, do: send(pid, :wait)
      {state, _, _, _} = sweep(new())

      [row] = for p <- Processes.snapshot(state.table), p.pid == Identity.pid_text(pid), do: p
      assert row.message_queue_len == 50
      stop(pid)
    end
  end

  describe "series for one process" do
    test "a process with a name has them, and one without does not" do
      name = unique(:named_worker)
      named = worker(name: name)
      plain = worker()

      {state, _, _, _} = sweep(new())
      {_state, batch, _, _} = sweep(state)

      labels = [pid: Identity.pid_text(named)]
      assert [{_, has, _}] = all(batch, "beam_proc_memory_bytes", labels)

      assert has == [
               {"proc", "#{name}#{Identity.pid_text(named)}"},
               {"pid", Identity.pid_text(named)},
               {"group", "named_worker"},
               {"app", "none"}
             ]

      assert value(batch, "beam_proc_memory_bytes", labels) > 0
      assert value(batch, "beam_proc_reductions", labels) > 0
      assert value(batch, "beam_proc_reductions_per_sec", labels) >= 0
      assert value(batch, "beam_proc_message_queue_len", labels) == 0
      assert all(batch, "beam_proc_memory_bytes", pid: Identity.pid_text(plain)) == []

      GenServer.stop(named)
      GenServer.stop(plain)
    end

    test "a process without a name has them if it is large" do
      plain = worker()
      GenServer.call(plain, {:hold, 300_000})

      {state, _, _, _} = sweep(new(notable_memory: 1024 * 1024))
      {_state, batch, _, _} = sweep(state)

      labels = [pid: Identity.pid_text(plain)]
      assert value(batch, "beam_proc_memory_bytes", labels) > 1024 * 1024
      assert [{_, [{"proc", proc} | _], _}] = all(batch, "beam_proc_memory_bytes", labels)
      assert proc == @group <> Identity.pid_text(plain)
      GenServer.stop(plain)
    end

    test "a process has them once it has lived long enough" do
      name = unique(:young_worker)
      pid = worker(name: name)

      state = new(min_age: 3600)
      {state, _, _, _} = sweep(state)
      {_state, batch, _, _} = sweep(state)

      assert all(batch, "beam_proc_memory_bytes", pid: Identity.pid_text(pid)) == []
      # It is in the totals all the same.
      assert value(batch, "beam_group_processes", group: "young_worker") == 1
      GenServer.stop(pid)
    end

    test "only so many processes have them, and those that do keep them" do
      state = new(max_processes: 2)
      # The first sweep finds them, and the second finds them old enough.
      {state, _, _, _} = sweep(state)
      {state, first, _, _} = sweep(state)
      {state, second, _, _} = sweep(state)

      assert Processes.admitted(state) == 2
      chosen = first |> labelled("beam_proc_memory_bytes", :pid) |> Enum.sort()
      assert length(chosen) == 2
      assert second |> labelled("beam_proc_memory_bytes", :pid) |> Enum.sort() == chosen
      assert value(second, "beam_acct_processes_reported") == 2
    end

    test "a place is given up when the process ends" do
      name = unique(:brief_worker)
      pid = worker(name: name)
      state = new(max_processes: 1000)
      {state, _, _, _} = sweep(state)
      {state, _, _, _} = sweep(state)
      before = Processes.admitted(state)
      assert before > 0

      stop(pid)

      {state, [_], _room, 0} =
        Processes.ended(state, [{pid, Ending.of(:killed), :erlang.monotonic_time()}])

      assert Processes.admitted(state) == before - 1
    end
  end

  describe "a process that ended" do
    test "is described by what was heard of it and what the last sweep saw" do
      state = new()
      pid = worker()
      started = :erlang.monotonic_time()

      {state, [], []} = Processes.heard(state, [born(pid, self(), started)])
      GenServer.call(pid, {:work, 100_000})
      {state, _, _, _} = sweep(state)
      {:reductions, used} = Process.info(pid, :reductions)
      stop(pid)

      {state, [exit], []} = Processes.heard(state, [exited(pid, :killed)])
      {state, [ended], _room, 0} = Processes.ended(state, [exit])

      assert %Ended{group: @group, source: :traced, born: true} = ended
      assert ended.pid == Identity.pid_text(pid)
      assert ended.path == "TimelessBeamAcct.ProcessesTest.Worker.init/1"
      assert ended.parent == Identity.pid_text(self())
      assert ended.ending.status == "killed"
      assert ended.since == Processes.epoch_us(started)
      assert ended.ended >= ended.since
      assert ended.figures.reductions > 10_000
      assert ended.figures.reductions <= used
      assert ended.figures.peak_memory >= ended.figures.memory
      assert ended.figures.at >= ended.since

      assert Processes.known(state, pid) == nil
    end

    test "is described as its parent calls it, though the parent ended in the same tick" do
      state = new()
      parent = worker(name: unique(:the_parent))
      child = worker()

      {state, [], []} = Processes.heard(state, [born(parent, self()), born(child, parent)])
      stop(child)
      stop(parent)

      {state, exits, []} =
        Processes.heard(state, [exited(parent, :killed), exited(child, :killed)])

      {_state, [was_parent, was_child], _room, 0} = Processes.ended(state, exits)

      assert was_parent.group == "the_parent"
      assert was_child.parent == was_parent.pid
      assert was_child.parent_group == "the_parent"
    end

    test "that ended registered is recorded under the name it ended under" do
      state = new()
      pid = worker()
      now = :erlang.monotonic_time()

      # As the VM says it: that it ended, and then that it gave up its name.
      {state, exits, []} =
        Processes.heard(state, [
          born(pid, self(), now),
          {0, :name, now + 1, pid, :the_front_desk},
          {0, :exit, now + 2, pid, Ending.of(:shutdown)},
          {0, :unname, now + 3, pid, :the_front_desk}
        ])

      stop(pid)
      {_state, [ended], _room, 0} = Processes.ended(state, exits)

      assert ended.name == "the_front_desk"
      assert ended.group == "the_front_desk"
    end

    test "that gave up its name before it ended is recorded without it" do
      state = new()
      pid = worker()
      now = :erlang.monotonic_time()

      {state, exits, []} =
        Processes.heard(state, [
          born(pid, self(), now),
          {0, :name, now + 1, pid, :the_front_desk},
          {0, :unname, now + 2, pid, :the_front_desk},
          {0, :exit, now + 3, pid, Ending.of(:shutdown)}
        ])

      stop(pid)
      {_state, [ended], _room, 0} = Processes.ended(state, exits)

      assert ended.name == nil
      assert ended.group == @group
    end

    test "that no sweep saw has no figures" do
      state = new()
      pid = worker()
      {state, [], []} = Processes.heard(state, [born(pid, self())])
      stop(pid)

      {_state, [ended], _room, 0} =
        Processes.ended(state, [{pid, Ending.of(:normal), :erlang.monotonic_time()}])

      assert ended.figures == nil
      assert ended.born
    end

    test "that was never heard of is unknown, and is recorded all the same" do
      pid = worker()
      stop(pid)

      {_state, [ended], _room, 0} =
        Processes.ended(new(), [{pid, Ending.of(:normal), :erlang.monotonic_time()}])

      assert %Ended{group: "unknown", app: "none", born: false, figures: nil, place: nil} = ended
      assert ended.since == ended.ended
    end

    test "is counted in what its group and its application did" do
      state = new()
      {state, _, _, _} = sweep(state)

      one = worker()
      two = worker()
      {state, [], []} = Processes.heard(state, [born(one, self()), born(two, self())])
      stop(one)
      stop(two)

      {state, exits, []} =
        Processes.heard(state, [exited(one, :normal), exited(two, {:timeout, :call})])

      {state, _, _room, 0} = Processes.ended(state, exits)
      {_state, batch, [], _} = sweep(state)

      # Neither lived to the sweep, and the group has no processes now.
      assert value(batch, "beam_group_processes", group: @group) == 0
      assert value(batch, "beam_group_spawns_per_sec", group: @group) > 0
      assert value(batch, "beam_group_exits_per_sec", group: @group) > 0
      failures = value(batch, "beam_group_failures_per_sec", group: @group)
      exits = value(batch, "beam_group_exits_per_sec", group: @group)
      # One of the two that ended. Each is kept to the precision it was
      # measured to, so twice the one is the other to within that.
      assert_in_delta failures * 2, exits, exits * 0.01

      # And what was counted is counted once.
      {_state, batch, [], _} = sweep(state |> Map.put(:tallies, %{groups: %{}, apps: %{}}))
      assert value(batch, "beam_group_exits_per_sec", group: @group) in [nil, 0.0]
    end

    test "has its place in a trace" do
      state = new()
      request = worker()
      query = worker()

      {state, [], []} =
        Processes.heard(state, [
          # Heard of before the process that started it.
          born(query, request),
          born(request, Process.whereis(:kernel_sup))
        ])

      stop(query)
      stop(request)

      {_state, [was_query, was_request], _room, 0} =
        Processes.ended(state, [
          {query, Ending.of(:killed), :erlang.monotonic_time()},
          {request, Ending.of(:killed), :erlang.monotonic_time()}
        ])

      assert was_request.place.parent_span_id == nil
      assert was_query.place.trace_id == was_request.place.trace_id
      assert was_query.place.parent_span_id == was_request.place.span_id
    end

    test "has no place if spans are not kept" do
      state = new(traces: false)
      pid = worker()
      {state, [], []} = Processes.heard(state, [born(pid, self())])
      stop(pid)

      {_state, [ended], _room, 0} =
        Processes.ended(state, [{pid, Ending.of(:killed), :erlang.monotonic_time()}])

      assert ended.place == nil
    end
  end

  describe "when more end than there is room to describe" do
    test "those there is room for are described, and the rest are counted" do
      state = new()
      {state, _, _, _} = sweep(state)
      workers = for _ <- 1..6, do: worker()
      {state, [], []} = Processes.heard(state, Enum.map(workers, &born(&1, self())))
      Enum.each(workers, &stop/1)

      exits =
        for {pid, n} <- Enum.with_index(workers) do
          {pid, Ending.of(if(n < 4, do: :normal, else: :killed)), :erlang.monotonic_time()}
        end

      {state, described, room, let_go} = Processes.ended(state, exits, %{ordinary: 1, failed: 1})

      assert [%Ended{ending: %{status: "normal"}}, %Ended{ending: %{status: "killed"}}] =
               described

      assert room == %{ordinary: 0, failed: 0}
      assert let_go == 4
      assert Enum.all?(workers, &(Processes.known(state, &1) == nil))

      # All six are in what the group did.
      {_state, batch, _, _} = sweep(state)
      exits = value(batch, "beam_group_exits_per_sec", group: @group)
      failures = value(batch, "beam_group_failures_per_sec", group: @group)
      assert_in_delta failures * 3, exits, exits * 0.01
    end
  end

  describe "a process that is gone, with no word of its end" do
    test "is accounted at the next sweep, with the figures of the last that saw it" do
      state = new()
      pid = worker()
      GenServer.call(pid, {:work, 100_000})
      {state, _, [], _} = sweep(state)
      {:reductions, used} = Process.info(pid, :reductions)
      stop(pid)

      {state, batch, [gone], _} = sweep(state)

      assert %Ended{source: :sampled, born: false, group: @group} = gone
      assert gone.ending == Ending.unknown()
      assert gone.figures.reductions > 10_000
      assert gone.figures.reductions <= used
      assert gone.ended > gone.since
      assert Processes.known(state, pid) == nil
      assert value(batch, "beam_group_exits_per_sec", group: @group) > 0
      # How it ended is not known, so it is not known to have failed.
      assert value(batch, "beam_group_failures_per_sec", group: @group) == 0

      {_state, _, [], _} = sweep(state)
    end

    test "waits one sweep for word of its end, when word is expected" do
      state = new() |> Processes.listening(true)
      pid = worker()
      {state, _, [], _} = sweep(state)
      stop(pid)

      {state, _, [], _} = sweep(state)
      assert Processes.known(state, pid) != nil
      {state, _, [gone], _} = sweep(state)
      assert gone.pid == Identity.pid_text(pid)
      assert Processes.known(state, pid) == nil
    end

    test "is accounted once, if word of its end comes while it waits" do
      state = new() |> Processes.listening(true)
      pid = worker()
      {state, _, [], _} = sweep(state)
      stop(pid)
      {state, _, [], _} = sweep(state)

      {state, [ended], _room, 0} =
        Processes.ended(state, [{pid, Ending.of(:killed), :erlang.monotonic_time()}])

      assert ended.source == :traced
      assert ended.ending.status == "killed"
      {_state, _, [], _} = sweep(state)
    end
  end

  describe "what a process is called" do
    test "changes when it takes a name, and when it gives it up" do
      state = new()
      pid = worker()
      {state, [], []} = Processes.heard(state, [born(pid, self())])
      assert Processes.known(state, pid).group == @group

      {state, [], []} = Processes.heard(state, [{0, :name, 0, pid, :taken_name_7}])
      assert %{name: "taken_name_7", group: "taken_name"} = Processes.known(state, pid)

      {state, [], []} = Processes.heard(state, [{0, :unname, 0, pid, :taken_name_7}])
      assert %{name: nil, group: @group} = Processes.known(state, pid)
      GenServer.stop(pid)
    end

    test "is what a sweep finds it registered as, where no word of a name came" do
      state = new()
      pid = worker()
      {state, _, _, _} = sweep(state)
      assert Processes.known(state, pid).group == @group

      name = unique(:found_name)
      Process.register(pid, name)
      {state, _, _, _} = sweep(state)
      assert %{group: "found_name"} = Processes.known(state, pid)
      assert Processes.known(state, pid).name == Atom.to_string(name)
      GenServer.stop(pid)
    end

    test "is what a task was given to do, once it has taken it up" do
      state = new()
      pid = worker()

      task =
        Identity.of_spawn(
          {Task.Supervised, :reply, [{node(), self(), self()}, [self()], :nomonitor]}
        )

      {state, [], []} =
        Processes.heard(state, [
          {0, :born, :erlang.monotonic_time(), pid, {self(), task}},
          {0, :call, :erlang.monotonic_time(), pid, {MyApp.Report, :build, 2}}
        ])

      assert %{group: "MyApp.Report.build/2", path: "MyApp.Report.build/2"} =
               Processes.known(state, pid)

      assert Processes.known(state, pid).call == {MyApp.Report, :build, 2}
      GenServer.stop(pid)
    end

    test "is the label it gave itself, unless someone gave it a name" do
      state = new()
      pid = worker()

      {state, [], []} =
        Processes.heard(state, [born(pid, self()), {0, :label, 0, pid, "connection"}])

      assert %{group: "connection", name: nil} = Processes.known(state, pid)

      {state, [], []} = Processes.heard(state, [{0, :name, 0, pid, :the_front_door}])
      assert %{group: "the_front_door"} = Processes.known(state, pid)

      {state, [], []} = Processes.heard(state, [{0, :label, 0, pid, "listener"}])
      assert %{group: "the_front_door"} = Processes.known(state, pid)

      {state, [], []} = Processes.heard(state, [{0, :unname, 0, pid, :the_front_door}])
      assert %{group: "listener"} = Processes.known(state, pid)
      GenServer.stop(pid)
    end

    test "is asked of it when a sweep first finds it alive" do
      state = new()
      task = Task.async(fn -> receive(do: (:stop -> :ok)) end)

      identity =
        Identity.of_spawn(
          {Task.Supervised, :reply, [{node(), self(), self()}, [self()], :nomonitor]}
        )

      {state, [], []} =
        Processes.heard(state, [
          {0, :born, :erlang.monotonic_time(), task.pid, {self(), identity}}
        ])

      # All that was heard is that it is a task.
      assert Processes.known(state, task.pid).group == "Task.Supervised.reply/3"

      {state, _, _, _} = sweep(state)
      assert Processes.known(state, task.pid).group =~ "fn in TimelessBeamAcct.ProcessesTest."
      send(task.pid, :stop)
      Task.await(task)
    end
  end

  describe "a snapshot" do
    test "is of every process a sweep has seen, as it was then" do
      name = unique(:snapped_worker)
      pid = worker(name: name)
      state = new()
      assert Processes.snapshot(state.table) == []

      {state, _, _, _} = sweep(state)
      GenServer.call(pid, {:work, 500_000})
      {state, _, _, found} = sweep(state)

      snapshot = Processes.snapshot(state.table, 1_000_000.0)
      assert length(snapshot) == found.processes

      [mine] = Enum.filter(snapshot, &(&1.pid == Identity.pid_text(pid)))

      assert %{name: _, group: "snapped_worker", app: "none", registered: true, age_known: false} =
               mine

      assert mine.name == Atom.to_string(name)
      assert mine.reductions_per_sec > 0
      assert_in_delta mine.work_pct, mine.reductions_per_sec / 10_000, 0.001
      assert mine.memory_bytes > 0
      assert mine.age_seconds >= 0
      GenServer.stop(pid)
    end

    test "of a collector that is not running is empty" do
      assert Processes.snapshot(:no_such_table) == []
    end
  end
end
