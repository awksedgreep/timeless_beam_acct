defmodule TimelessBeamAcct.Watch.DataTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.Watch.Data
  alias TimelessBeamAcct.Watched

  test "samples are the series of each metric, whoever they were read by" do
    # As a collector has them, and as a store gives them back.
    collector = [{"beam_group_processes", [{"group", "A"}], 3}]
    store = [{"beam_group_processes", %{"group" => "A", "host" => "ohm", "node" => "a@ohm"}, 3}]

    assert Data.series(collector) == %{"beam_group_processes" => [{%{"group" => "A"}, 3}]}
    assert Data.series(store) == Data.series(collector)
  end

  test "a moment is the node, its groups, its applications, and its processes" do
    snapshot = Watched.snapshot(1000.0)
    assert snapshot.at == 1000.0
    refute Data.empty?(snapshot)

    assert snapshot.vm.run_queue == 2.0
    # Of all the schedulers together, and not of one of them.
    assert snapshot.vm.schedulers == 12.5
    assert snapshot.vm.memory == 131.0 * 1024 * 1024
    assert snapshot.vm.uptime == 7380.0
    # What was not read is not there.
    refute Map.has_key?(snapshot.vm, :ports)

    assert Enum.map(snapshot.groups, & &1.name) == ["MyApp.Repo", "MyApp.Worker", "New.Thing"]
    worker = Enum.at(snapshot.groups, 1)

    assert %{work: 12.0, processes: 50.0, queue: 1200.0, reductions: 5700.0, exits: 2.5} = worker
    assert worker.failures == 0.5

    # A group with a place and no rates yet is there, with no figures.
    assert %{work: nil, reductions: nil} = new = Enum.at(snapshot.groups, 2)
    assert new.processes == 0

    assert Enum.map(snapshot.apps, & &1.name) == ["my_app", "none"]

    assert [repo, worker] = snapshot.processes

    assert %{name: "MyApp.Repo", proc: "MyApp.Repo<0.512.0>", pid: "<0.512.0>", app: "my_app"} =
             repo

    assert %{name: "worker_7", group: "MyApp.Worker", work: 1.5, queue: 1200.0} = worker
    assert worker.reductions == 4.0e4
  end

  test "a moment with nothing in it is empty" do
    assert Data.empty?(Data.read(5.0, %{}))
    assert Data.empty?(%Data{})
  end

  test "the processes a collector has are the processes of a moment" do
    collector = [
      %{
        pid: "<0.700.0>",
        name: "worker_7",
        group: "MyApp.Worker",
        app: "my_app",
        work_pct: 1.5,
        reductions: 40_000,
        reductions_per_sec: 700.0,
        memory_bytes: 60_000,
        message_queue_len: 3
      },
      # Without a name of its own, it is known by what it is.
      %{pid: "<0.9.0>", name: "MyApp.Job.run/1", group: "MyApp.Job.run/1", app: "none"}
    ]

    assert [job, worker] = Data.from_snapshot(collector)
    assert %{proc: "worker_7<0.700.0>", name: "worker_7", work: 1.5, memory: 60_000} = worker
    assert worker.queue == 3
    assert %{proc: "MyApp.Job.run/1<0.9.0>", work: nil, memory: nil} = job

    # They take the place of those that have series.
    snapshot = Data.read(1.0, Data.series(Watched.samples()), [worker])
    assert snapshot.processes == [worker]
    assert length(snapshot.groups) == 3
  end
end
