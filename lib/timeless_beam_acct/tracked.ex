defmodule TimelessBeamAcct.Tracked do
  @moduledoc """
  What is kept of each process known to be running.

  One row of a table, for as long as the process lives. The table is the
  collector's and anything may read it, which is how
  `TimelessBeamAcct.top/1` looks at the processes without asking the
  collector to stop what it is doing.

  Times are monotonic, in native units.

  | field | is |
  |---|---|
  | `gen` | the last sweep that saw it, or the one that was latest when it was heard of |
  | `since` | when it started, if `born`; else when it was first seen |
  | `parent` | the process that started it |
  | `caller` | the process it was started on behalf of, if that is known and is another |
  | `call` | what it was started with |
  | `base` | its group, leaving aside the name it is registered under |
  | `group` | its group |
  | `starter` | it starts jobs and is not part of them |
  | `root` | the process at the root of its trace: itself, if it is one. `nil` until it is given its place |
  | `trace_since` | when that trace began |
  | `trace_parent` | the process its span is a child of, if that is in the same trace |
  | `admitted` | it has series of its own |
  | `identified` | how often it has been asked what it is |
  | `swept` | when a sweep last saw it, or `nil` |
  | `reductions`, `memory`, `queue` | as of then |
  | `rate` | reductions a second, over the interval before then |
  """

  require Record

  @fields [
    pid: nil,
    gen: 0,
    since: 0,
    born: false,
    parent: nil,
    caller: nil,
    call: nil,
    base: "unknown",
    group: "unknown",
    path: nil,
    name: nil,
    app: nil,
    starter: false,
    root: nil,
    trace_since: 0,
    trace_parent: nil,
    admitted: false,
    identified: 0,
    swept: nil,
    reductions: 0,
    memory: 0,
    peak_memory: 0,
    queue: 0,
    rate: nil
  ]

  Record.defrecord(:tracked, @fields)

  @type t :: record(:tracked, pid: pid())

  @doc "A row, from fields that are not known until it is made."
  @spec new(keyword()) :: t()
  def new(fields) do
    for {field, value} <- fields, reduce: tracked() do
      row -> put_elem(row, position(field), value)
    end
  end

  @doc "A row as a map, for those who read the table and are not the collector."
  @spec to_map(t()) :: map()
  def to_map(row) when Record.is_record(row, :tracked) do
    [:tracked | values] = Tuple.to_list(row)
    @fields |> Keyword.keys() |> Enum.zip(values) |> Map.new()
  end

  for {{field, _default}, index} <- Enum.with_index(@fields, 1) do
    defp position(unquote(field)), do: unquote(index)
  end

  @doc "Where the key of a row is."
  @spec keypos() :: pos_integer()
  def keypos, do: tracked(:pid) + 1
end
