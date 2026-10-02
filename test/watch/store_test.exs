defmodule TimelessBeamAcct.Watch.StoreTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.Span
  alias TimelessBeamAcct.Watch.{Live, Memory, Store}

  defp span(trace, id, parent, name, start, more \\ []) do
    struct!(
      %Span{
        trace_id: <<trace::128>>,
        span_id: <<id::64>>,
        parent_span_id: parent && <<parent::64>>,
        name: name,
        service: "my_app",
        ok: true,
        start_ns: start * 1_000_000_000,
        duration_ns: 1_000_000_000
      },
      more
    )
  end

  test "a record is a row: what ended, how, and with what figures" do
    exit =
      Store.exit(100.5, :warning, %{
        "service" => "MyApp.Worker",
        "name" => "worker_7",
        "pid" => "<0.7.0>",
        "app" => "my_app",
        "status" => "killed",
        "elapsed_seconds" => 2.5,
        "reductions" => 1200,
        "peak_memory_bytes" => 4096
      })

    assert %{at: 100.5, name: "MyApp.Worker", pid: "<0.7.0>", app: "my_app"} = exit
    assert %{status: "killed", level: "warning", elapsed: 2.5, whole: true} = exit
    assert %{reductions: 1200, peak_memory: 4096, process: "MyApp.Worker (worker_7)"} = exit

    # Of a process that was running before the collector was, it is how
    # long the collector knew of it; and of one no sweep saw, no figures.
    exit = Store.exit(1.0, "info", %{"service" => "A", "name" => "A", "seen_seconds" => 9.0})
    assert %{elapsed: 9.0, whole: false, reductions: nil, peak_memory: nil, process: "A"} = exit
    assert %{elapsed: nil, whole: true, pid: "", status: ""} = Store.exit(1.0, "info", %{})
  end

  test "the jobs among spans are the traces of more than one, the last to start first" do
    spans = [
      span(1, 1, nil, "MyApp.Batch", 100, attributes: %{"process.reductions" => 10}),
      span(1, 2, 1, "MyApp.Worker", 101, ok: false, ending: "killed"),
      # A trace of one process is not a job.
      span(2, 3, nil, "MyApp.Session", 102),
      span(3, 4, nil, "MyApp.Report.build/2", 110),
      span(3, 5, 4, "fn in MyApp.Report.build/2", 111, duration_ns: 5_000_000_000)
    ]

    assert [report, batch] = Store.jobs_of(spans, 80)
    assert %{name: "MyApp.Report.build/2", started: 110.0, duration: 6.0, processes: 2} = report
    assert %{failed: 0, reductions: nil, running: false, app: "my_app"} = report
    assert %{name: "MyApp.Batch", failed: 1, reductions: 10, duration: 2.0} = batch
    assert batch.tree == ["MyApp.Batch  1.0s, 10 reductions", "└─ MyApp.Worker  1.0s  [killed]"]

    assert Store.jobs_of([], 80) == []
  end

  test "the spacing of samples is the gap that half of them are no further apart than" do
    every_ten = for n <- 0..9, do: {100.0 + 10 * n, 1.0}
    assert Store.spacing_of(every_ten) == 10.0
    # A tick that was missed is a gap, and not the spacing.
    assert Store.spacing_of(List.delete_at(every_ten, 4)) == 10.0
    # Too few to say.
    assert Store.spacing_of([{1.0, 1.0}, {11.0, 1.0}]) == nil
    assert Store.spacing_of([]) == nil
  end

  test "how far back a moment is, is said" do
    assert Store.ago(1000.0, 700.0) == "5m00s ago"
    assert Store.ago(1000.0, 2000.0) == "0ms ago"
  end

  test "what a collector that is not there keeps in memory is nothing" do
    store = %Memory{live: %Live{node: node(), name: :no_such_collector}}
    reach = %{until: 10.0, span: 10.0, limit: 5}

    assert Store.range(store) == {nil, store}
    assert Store.at(store, 1.0, 1.0, [:vm]) == {:ok, %{}}
    assert Store.history(store, "m", "k", "w", 0.0, 1.0) == []
    assert Store.spacing(store, 1.0) == {nil, nil}
    assert Store.timeline(store, 0.0, 1.0) == {[], 10.0}
    assert Store.incidents(store, 0.0, 1.0, 10) == {[], store}
    assert Store.exits(store, reach, fn _ -> true end) == {:ok, []}
    assert Store.jobs(store, reach, 80, fn _ -> true end) == {:ok, []}
    assert Store.record(store, "A", "<0.1.0>", 0.0) == nil
  end

  test "a node is asked, and one that cannot be says so" do
    assert {:error, why} = Live.status(%Live{node: node(), name: :no_such_collector})
    assert why =~ "has no collector running"

    gone = %Live{node: :"nobody_#{System.unique_integer([:positive])}@nowhere", timeout: 500}
    assert {:error, why} = Live.status(gone)
    assert why =~ "did not answer"
    assert {:error, _} = Live.read(gone, 30.0)
    assert Live.records(gone) == []
    assert Live.spans(gone) == []

    # A process that is not running has nothing said of it.
    live = %Live{node: node()}
    {pid, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert Live.describe(live, pid |> inspect() |> String.replace("#PID", "")) == nil
    assert Live.describe(live, "not a pid") == nil

    lines = Live.describe(live, self() |> inspect() |> String.replace("#PID", ""))
    assert {"status", status} = List.keyfind(lines, "status", 0)
    assert status in ["running", "waiting"]
    assert List.keymember?(lines, "stack", 0)
    assert {"ended", "It is still running."} in lines
  end
end
