defmodule TimelessBeamAcct.HistoryTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.{Batch, Event, History, Options, Span}

  defp new(capacity) do
    name = :"history_test_#{System.unique_integer([:positive])}"
    {name, History.new(Options.new!(name: name, sink: :stdout, history: capacity))}
  end

  defp event(n), do: %Event{ts_us: n, level: :info, message: "#{n}"}

  defp span(n),
    do: %Span{
      trace_id: <<n::128>>,
      span_id: <<n::64>>,
      name: "#{n}",
      service: "app",
      start_ns: n,
      duration_ns: 1
    }

  test "what is kept is read back, oldest first" do
    {name, history} = new(10)
    history = History.add(history, [event(1), event(2)], [span(1)])
    History.add(history, [event(3)], [span(2), span(3)])

    assert Enum.map(History.events(name), & &1.ts_us) == [1, 2, 3]
    assert Enum.map(History.spans(name), & &1.start_ns) == [1, 2, 3]
  end

  test "the oldest make way for the newest" do
    {name, history} = new(3)

    Enum.reduce(1..10, history, fn n, history -> History.add(history, [event(n)], [span(n)]) end)

    assert Enum.map(History.events(name), & &1.ts_us) == [8, 9, 10]
    assert Enum.map(History.spans(name), & &1.start_ns) == [8, 9, 10]
  end

  test "more than there is room for, all at once, is cut to what there is room for" do
    {name, history} = new(2)
    History.add(history, Enum.map(1..5, &event/1), [])
    assert Enum.map(History.events(name), & &1.ts_us) == [4, 5]
  end

  test "with no room, nothing is kept" do
    {name, history} = new(0)
    History.add(history, [event(1)], [span(1)])
    assert History.events(name) == []
    assert History.spans(name) == []
  end

  test "of a collector that is not running there is none" do
    assert History.events(:no_such_collector) == []
    assert History.spans(:no_such_collector) == []
    assert History.reading(:no_such_collector) == []
  end

  defp batch(ts, samples) do
    Enum.reduce(samples, Batch.new(ts), fn {name, labels, value}, batch ->
      Batch.push(batch, name, labels, value)
    end)
  end

  test "the last reading is the last samples of each metric, and when they were read" do
    {name, history} = new(10)
    assert History.reading(name) == []

    history =
      History.read(
        history,
        batch(100, [
          {"beam_vm_run_queue", [], 1},
          {"beam_group_processes", [{"group", "A"}], 3},
          {"beam_group_processes", [{"group", "B"}], 4}
        ])
      )

    assert Enum.sort(History.reading(name)) == [
             {"beam_group_processes", 100, [{[{"group", "A"}], 3}, {[{"group", "B"}], 4}]},
             {"beam_vm_run_queue", 100, [{[], 1}]}
           ]

    # A reading of the node alone leaves those of the processes as they
    # were, and each says when it was read.
    history = History.read(history, batch(110, [{"beam_vm_run_queue", [], 2}]))

    assert Enum.sort(History.reading(name)) == [
             {"beam_group_processes", 100, [{[{"group", "A"}], 3}, {[{"group", "B"}], 4}]},
             {"beam_vm_run_queue", 110, [{[], 2}]}
           ]

    # A group that has gone is not among the samples that take their place.
    history = History.read(history, batch(120, [{"beam_group_processes", [{"group", "B"}], 5}]))
    assert {"beam_group_processes", 120, [{[{"group", "B"}], 5}]} in History.reading(name)

    # A reading with nothing in it takes the place of nothing.
    History.read(history, Batch.new(130))
    assert length(History.reading(name)) == 2
  end

  test "no reading is kept by a history that keeps nothing" do
    {name, history} = new(0)
    History.read(history, batch(100, [{"beam_vm_run_queue", [], 1}]))
    assert History.reading(name) == []
  end
end
