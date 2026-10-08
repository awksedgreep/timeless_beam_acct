defmodule TimelessBeamAcct.Watch.RealPlanesTest do
  @moduledoc """
  A collector in this node, writing to planes that are running, and what
  it wrote read back by what draws a node in a terminal.

  The tests of `TimelessBeamAcct.Watch.Planes` are against a server that
  answers what the test tells it to. This one is against the servers
  themselves, and is what says that the questions the screen asks are
  questions the planes answer.

  It is run as `test/planes_test.exs` is, and refuses the planes that one
  refuses: `mix test --only planes`.
  """

  use ExUnit.Case, async: false

  alias TimelessBeamAcct.{RealPlanes, Tracer, Watch}
  alias TimelessBeamAcct.Watch.{Data, Planes, State, Store}

  @moduletag :planes
  @moduletag :capture_log
  @moduletag timeout: 60_000

  # How long a plane is given to show what it answered for.
  # VictoriaMetrics, as it is started unless told otherwise, does not
  # answer for the last thirty seconds (`-search.latencyOffset`): what the
  # collector read just now is asked for until then, and no longer.
  @within_ms 45_000

  defp eventually(read, enough?, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @within_ms
    value = read.()

    cond do
      enough?.(value) -> value
      System.monotonic_time(:millisecond) > deadline -> value
      true -> Process.sleep(200) && eventually(read, enough?, deadline)
    end
  end

  setup_all do
    options =
      case RealPlanes.sink_options() do
        {:ok, options} -> options
        {:error, why} -> raise "not run: " <> why
      end

    run = Base.encode16(:rand.bytes(6), case: :lower)
    name = :"watch_planes_#{run}"

    {:ok, _} =
      start_supervised(
        {TimelessBeamAcct,
         [
           name: name,
           sink: :http,
           host: "watch-test-" <> run,
           node: "watch-" <> run <> "@test",
           interval: 3600,
           process_interval: 3600,
           min_age: 0,
           anomalies: false
         ] ++ options}
      )

    # A job that fails, between two readings with rates; and a third, so
    # that there are three moments.
    :ok = TimelessBeamAcct.tick(name)
    Process.sleep(1100)

    {pid, ref} =
      spawn_monitor(fn ->
        Task.await(Task.async(fn -> :ok end))
        exit({:watch_test, run})
      end)

    assert_receive {:DOWN, ^ref, _, _, _}, 5_000
    Process.sleep(50)
    :ok = TimelessBeamAcct.tick(name)
    Process.sleep(1100)
    :ok = TimelessBeamAcct.tick(name)
    :ok = TimelessBeamAcct.flush(name)

    {:ok, watch} = Watch.new(node: node(), name: name)
    {:ok, name: name, watch: watch, run: run, pid: pid |> inspect() |> String.replace("#PID", "")}
  end

  test "the planes are those the collector says it writes to, of its node alone", context do
    assert %Planes{node: node, host: host} = context.watch.store
    assert node == "watch-#{context.run}@test"
    assert host == "watch-test-#{context.run}"
    assert context.watch.state.message == nil
  end

  test "the moments held are from the collector's first reading to its last", context do
    {range, _store} =
      eventually(fn -> Store.range(context.watch.store) end, fn {range, _} ->
        match?({first, last} when last - first >= 2, range)
      end)

    assert {first, last} = range
    assert last - first >= 2 and last - first < 30
    assert_in_delta last, System.os_time(:second), 30
  end

  test "a moment is the node as the collector read it", context do
    # A plane may make a sample findable a moment after it took it.
    {{_first, last}, store} =
      eventually(fn -> Store.range(context.watch.store) end, &match?({{_, _}, _}, &1))

    series =
      eventually(
        fn -> store |> Store.at(last, 30.0, [:vm, :groups, :apps, :processes]) |> elem(1) end,
        &(is_map(&1) and is_map_key(&1, "beam_group_work_pct"))
      )

    snapshot = Data.read(last, series)
    assert snapshot.vm.processes > 10
    assert is_number(snapshot.vm.memory) and is_number(snapshot.vm.schedulers)
    assert Enum.any?(snapshot.groups, &String.ends_with?(&1.name, ".Collector"))
    assert Enum.any?(snapshot.apps, &(&1.name == "kernel"))
    assert [_ | _] = snapshot.processes
    assert Enum.all?(snapshot.processes, &(&1.pid != "" and String.ends_with?(&1.proc, &1.pid)))

    # The history of one of its rows, and how far apart its samples are.
    group = Enum.find(snapshot.groups, &String.ends_with?(&1.name, ".Collector")).name
    history = Store.history(store, "beam_group_processes", "group", group, last - 600, last)
    assert [{_, 1.0} | _] = history
    assert {[_ | _], _step} = Store.timeline(store, last - 3600, last)
  end

  test "what ended is there, and how, and is found by what it was", context do
    reach = %{until: System.os_time(:second) + 1.0, span: 900.0, limit: 200}
    wanted = &(&1.pid == context.pid)

    assert {:ok, [exit]} =
             eventually(
               fn -> Store.exits(context.watch.store, reach, wanted) end,
               &match?({:ok, [_]}, &1)
             )

    assert exit.status == "watch_test"
    assert exit.fields["reason"] =~ context.run
    assert is_number(exit.elapsed)

    assert %{at: at, pid: pid} =
             Store.record(context.watch.store, exit.name, context.pid, exit.at - 5)

    assert {at, pid} == {exit.at, context.pid}
    assert Watch.ended(exit) |> List.keyfind("ended", 0) |> elem(1) =~ "exited watch_test, after"
  end

  @tag skip: if(Tracer.available?(), do: false, else: "this VM has no trace sessions")
  test "the job it was part of is a tree", context do
    reach = %{until: System.os_time(:second) + 1.0, span: 900.0, limit: 200}

    # VictoriaTraces makes a trace findable half a minute after it is
    # written, and the trace is read by its id.
    assert {:ok, [job | _]} =
             eventually(
               fn -> Store.jobs(context.watch.store, reach, 100, &(&1.failed > 0)) end,
               &match?({:ok, [_ | _]}, &1),
               System.monotonic_time(:millisecond) + 60_000
             )

    assert job.processes == 2
    assert [root, child] = job.tree
    assert root =~ "[exited watch_test]"
    assert child =~ "└─ "
  end

  test "the screen is of now, and of the moment gone back to", context do
    watch =
      eventually(
        fn -> Watch.read_moment(context.watch) end,
        &(&1.detail.range != nil and &1.detail.history != [])
      )

    assert State.live?(watch.state)
    assert watch.detail.error == nil
    {watch, lines} = Watch.screen(watch, {120, 40})
    text = Enum.join(lines, "\n")
    assert text =~ "● LIVE"
    assert text =~ ~r/GROUP\s+WORK%/
    assert text =~ "work, the 10m00s before"
    assert text =~ ~r/peak \d+\.\d%/

    # Back from now is the last moment the planes hold.
    {watch, :moment} = Watch.pressed(watch, [:left])
    {_first, last} = watch.detail.range
    # The collector was told an hour between readings, and a step is that.
    assert watch.state.at <= last

    watch =
      eventually(
        fn -> Watch.read_moment(%{watch | state: %{watch.state | at: last / 1}}) end,
        &(not Data.empty?(&1.snapshot))
      )

    assert watch.detail.error == nil
    refute Data.empty?(watch.snapshot)
    {_watch, lines} = Watch.screen(watch, {120, 40})
    assert Enum.join(lines, "\n") =~ "◀ "
  end
end
