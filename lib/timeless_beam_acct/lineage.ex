defmodule TimelessBeamAcct.Lineage do
  @moduledoc """
  The place of a process in a trace.

  A process has a start, a duration, and a parent, which is what a span is.
  What it does not have is a trace. The tree of processes has one root,
  `init`, and a trace of everything since the node started says nothing.

  ## A trace is a job

  A job is what a node does for something that is not the node: it answers
  a request, runs a task, handles a message from a queue. It begins with a
  process that a supervisor started, and it is that process and everything
  the process started, and so on down.

  So a process is the root of a trace if it was started by a supervisor,
  or by a process that is not known. Otherwise it is part of the trace of
  the process that started it.

  ## Except for servers

  A job ends. A server that a supervisor started is the root of a trace
  too, and everything it starts in a month would be one trace. So a
  process joins the trace of the process that started it only if it
  started within an hour of that trace (`:trace_max_age`). Past that, what
  a server starts is the root of a trace of its own.

  ## On behalf of

  A task is started by whoever asked for it, or by a task supervisor on
  behalf of whoever asked. Either way it is part of the job of the process
  that asked, and that is whose span it is a child of: its caller, where
  that is known, and not its parent.

  ## Ids are decided at the start

  A child ends before its parent. Its span is written first, and must
  already carry the trace id its parent's span will carry when the parent
  ends, minutes later. So a process's place is decided when it is first
  heard of, from what is known then, and does not change.

  And the ids are made, not drawn: a hash of the node's incarnation and
  the pid. A collector that is restarted gives a running process the id it
  gave it before.

  The hash is MD5, which the VM has in itself. Nothing is kept secret by
  it, and a collector that needed `:crypto` could not be loaded into a
  node that was built without it.
  """

  import TimelessBeamAcct.Tracked, only: [tracked: 1, tracked: 2]

  # How far up a chain of parents a place is looked for before giving up.
  # Nothing real is this deep, and a chain that is has an end somewhere.
  @depth 64

  @doc """
  What tells this run of the node from the one before, which had processes
  with the same pids.

  Made when first asked for and kept for as long as the node runs, so that
  a collector that is restarted gives out the ids it gave out before.
  """
  @spec incarnation() :: binary()
  def incarnation do
    key = {__MODULE__, :incarnation}

    case :persistent_term.get(key, nil) do
      nil ->
        made =
          :erlang.md5(
            :erlang.term_to_binary(
              {node(), :os.getpid(), :erlang.system_time(), :erlang.unique_integer(), make_ref()}
            )
          )

        :persistent_term.put(key, made)
        # If two asked at once, both are given what is kept.
        :persistent_term.get(key)

      kept ->
        kept
    end
  end

  @doc "The id of the span of a process."
  @spec span_id(binary(), pid()) :: <<_::64>>
  def span_id(incarnation, pid) when is_pid(pid),
    do: binary_part(:erlang.md5([incarnation, "span", :erlang.pid_to_list(pid)]), 0, 8)

  @doc "The id of the trace that has this process at its root."
  @spec trace_id(binary(), pid()) :: <<_::128>>
  def trace_id(incarnation, root) when is_pid(root),
    do: :erlang.md5([incarnation, "trace", :erlang.pid_to_list(root)])

  @doc """
  The place of a row in a trace, as ids. `nil` if it was given none.
  """
  @spec place(binary(), TimelessBeamAcct.Tracked.t()) :: TimelessBeamAcct.Ended.place() | nil
  def place(_incarnation, tracked(root: nil)), do: nil

  def place(incarnation, tracked(pid: pid, root: root, trace_parent: parent)) do
    %{
      trace_id: trace_id(incarnation, root),
      span_id: span_id(incarnation, pid),
      parent_span_id: parent && span_id(incarnation, parent)
    }
  end

  @doc """
  Give the process its place, and whatever else it has from the process
  that started it: the application it runs in.

  The process that started it is given its place first, if it has none
  yet: a child is heard of before its parent as often as after.

  `max_age` is in native units.
  """
  @spec settle(:ets.tid() | atom(), pid(), integer()) :: :ok
  def settle(table, pid, max_age), do: settle(table, pid, max_age, @depth)

  defp settle(table, pid, max_age, depth) do
    case :ets.lookup(table, pid) do
      [tracked(root: nil) = row] -> settle_row(table, row, max_age, depth)
      _placed_or_gone -> :ok
    end
  end

  defp settle_row(table, tracked(pid: pid, parent: parent, caller: caller) = row, max_age, depth) do
    started_by = known(table, parent, pid, max_age, depth)
    for = if caller && caller != parent, do: known(table, caller, pid, max_age, depth)
    above = for || started_by

    row = inherit(row, started_by)

    row =
      if above && joins?(row, above, max_age) do
        tracked(pid: above_pid, root: root, trace_since: since) = above
        tracked(row, root: root, trace_since: since, trace_parent: above_pid)
      else
        tracked(row, root: pid, trace_since: tracked(row, :since), trace_parent: nil)
      end

    :ets.insert(table, row)
    :ok
  end

  # The row of another process, with its place, or `nil` if it is not
  # known or is the process itself.
  defp known(_table, nil, _pid, _max_age, _depth), do: nil
  defp known(_table, pid, pid, _max_age, _depth), do: nil
  defp known(_table, _other, _pid, _max_age, 0), do: nil

  defp known(table, other, _pid, max_age, depth) do
    case :ets.lookup(table, other) do
      [tracked(root: nil)] ->
        settle(table, other, max_age, depth - 1)

        case :ets.lookup(table, other) do
          [tracked(root: root) = row] when not is_nil(root) -> row
          _ -> nil
        end

      [row] ->
        row

      [] ->
        nil
    end
  end

  defp joins?(row, above, max_age) do
    tracked(starter: starter, trace_since: trace_since) = above
    not starter and tracked(row, :since) - trace_since <= max_age
  end

  # A process runs in the application of the process that started it,
  # unless it has said otherwise, which is known only by asking it.
  defp inherit(tracked(app: nil) = row, tracked(app: app)), do: tracked(row, app: app)
  defp inherit(row, _started_by), do: row
end
