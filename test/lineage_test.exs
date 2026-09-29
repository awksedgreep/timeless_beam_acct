defmodule TimelessBeamAcct.LineageTest do
  use ExUnit.Case, async: true

  import TimelessBeamAcct.Tracked

  alias TimelessBeamAcct.{Lineage, Tracked}

  @hour 3_600_000

  setup do
    table = :ets.new(:lineage_test, [:set, :public, keypos: Tracked.keypos()])
    {:ok, table: table}
  end

  # Pids that are no one's: what is tested is the table.
  defp pid(n), do: :erlang.list_to_pid(~c"<0.#{10_000 + n}.0>")

  defp row(table, n, fields) do
    :ets.insert(table, Tracked.new([pid: pid(n)] ++ fields))
    pid(n)
  end

  defp settled(table, pid) do
    Lineage.settle(table, pid, @hour)
    [row] = :ets.lookup(table, pid)
    row
  end

  test "a process started by a supervisor is the root of a trace", %{table: table} do
    sup = row(table, 1, starter: true, app: "my_app", since: 0)
    worker = row(table, 2, parent: sup, since: 100)

    assert tracked(root: ^worker, trace_parent: nil, trace_since: 100, app: "my_app") =
             settled(table, worker)
  end

  test "what a process starts is part of its job", %{table: table} do
    sup = row(table, 1, starter: true, since: 0)
    request = row(table, 2, parent: sup, since: 100)
    query = row(table, 3, parent: request, since: 150)
    deeper = row(table, 4, parent: query, since: 160)

    assert tracked(root: ^request) = settled(table, request)

    assert tracked(root: ^request, trace_parent: ^request, trace_since: 100) =
             settled(table, query)

    assert tracked(root: ^request, trace_parent: ^query, trace_since: 100) =
             settled(table, deeper)
  end

  test "a process started by one that is not known is a root", %{table: table} do
    orphan = row(table, 2, parent: pid(99), since: 100)
    assert tracked(root: ^orphan, trace_parent: nil) = settled(table, orphan)

    alone = row(table, 3, parent: nil, since: 100)
    assert tracked(root: ^alone) = settled(table, alone)
  end

  test "a child heard of before its parent is placed after it", %{table: table} do
    sup = row(table, 1, starter: true, since: 0)
    # Neither has a place yet, and the child is asked for first.
    child = row(table, 3, parent: pid(2), since: 150)
    parent = row(table, 2, parent: sup, since: 100)

    assert tracked(root: ^parent, trace_parent: ^parent) = settled(table, child)
    assert [tracked(root: ^parent)] = :ets.lookup(table, parent)
  end

  test "what a server starts after an hour is a job of its own", %{table: table} do
    sup = row(table, 1, starter: true, since: 0)
    server = row(table, 2, parent: sup, since: 100)
    early = row(table, 3, parent: server, since: 100 + @hour)
    late = row(table, 4, parent: server, since: 101 + @hour)
    of_late = row(table, 5, parent: late, since: 102 + @hour)

    settled(table, server)
    assert tracked(root: ^server, trace_parent: ^server) = settled(table, early)
    assert tracked(root: ^late, trace_parent: nil, trace_since: since) = settled(table, late)
    assert since == 101 + @hour
    assert tracked(root: ^late, trace_parent: ^late) = settled(table, of_late)
  end

  test "a task is part of the job of whoever asked for it", %{table: table} do
    sup = row(table, 1, starter: true, app: "my_app", since: 0)
    tasks = row(table, 2, parent: sup, starter: true, app: "tasks_app", since: 1)
    request = row(table, 3, parent: sup, app: "my_app", since: 100)
    task = row(table, 4, parent: tasks, caller: request, since: 150)

    assert tracked(root: ^request, trace_parent: ^request, app: app) = settled(table, task)
    # It runs where the process that started it runs.
    assert app == "tasks_app"
  end

  test "a task whose caller is not known is placed by what started it", %{table: table} do
    sup = row(table, 1, starter: true, since: 0)
    request = row(table, 3, parent: sup, since: 100)
    task = row(table, 4, parent: request, caller: pid(99), since: 150)

    assert tracked(root: ^request, trace_parent: ^request) = settled(table, task)
  end

  test "a place, once given, is kept", %{table: table} do
    sup = row(table, 1, starter: true, since: 0)
    request = row(table, 2, parent: sup, since: 100)
    child = row(table, 3, parent: request, since: 150)
    settled(table, child)

    :ets.delete(table, request)
    assert tracked(root: ^request, trace_parent: ^request) = settled(table, child)
  end

  test "an application that is known is not replaced by the parent's", %{table: table} do
    sup = row(table, 1, starter: true, app: "my_app", since: 0)
    worker = row(table, 2, parent: sup, app: "other_app", since: 100)
    assert tracked(app: "other_app") = settled(table, worker)
  end

  test "a chain with no end is given up on", %{table: table} do
    a = row(table, 1, parent: pid(2), since: 100)
    _b = row(table, 2, parent: pid(1), since: 100)
    assert tracked(root: root) = settled(table, a)
    assert is_pid(root)
  end

  describe "ids" do
    test "are the same for the same process, and differ between processes and runs" do
      one = Lineage.incarnation()
      assert byte_size(one) == 16
      assert Lineage.incarnation() == one

      assert Lineage.span_id(one, pid(1)) == Lineage.span_id(one, pid(1))
      assert Lineage.span_id(one, pid(1)) != Lineage.span_id(one, pid(2))
      assert Lineage.span_id(one, pid(1)) != Lineage.span_id(<<0::128>>, pid(1))
      assert byte_size(Lineage.span_id(one, pid(1))) == 8
      assert byte_size(Lineage.trace_id(one, pid(1))) == 16
    end

    test "a span is a child of the span of its parent in the trace", %{table: table} do
      sup = row(table, 1, starter: true, since: 0)
      request = row(table, 2, parent: sup, since: 100)
      child = row(table, 3, parent: request, since: 150)
      inc = <<7::128>>

      root_place = Lineage.place(inc, settled(table, request))
      child_place = Lineage.place(inc, settled(table, child))

      assert root_place.parent_span_id == nil
      assert root_place.trace_id == Lineage.trace_id(inc, request)
      assert child_place.trace_id == root_place.trace_id
      assert child_place.parent_span_id == root_place.span_id
      assert child_place.span_id == Lineage.span_id(inc, child)
    end

    test "a row with no place has none", %{table: table} do
      row(table, 1, since: 0)
      [unplaced] = :ets.lookup(table, pid(1))
      assert Lineage.place(<<7::128>>, unplaced) == nil
    end
  end
end
