defmodule TimelessBeamAcct.HistoryTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.{Event, History, Options, Span}

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
  end
end
