defmodule TimelessBeamAcct.History do
  @moduledoc """
  The last records and spans, kept in memory.

  The stores are where the history is, and a canvas is how it is looked
  at. This is for the person at a shell on the node, who wants to know
  what ended in the last few minutes and has nothing to ask but the node:
  `TimelessBeamAcct.exits/1` and `TimelessBeamAcct.trees/1` read it.

  It holds `:history` of each and no more, the oldest making way for the
  newest, and it is gone when the collector is.
  """

  alias TimelessBeamAcct.{Event, Options, Span}

  @type t :: %__MODULE__{
          events: :ets.tid() | atom(),
          spans: :ets.tid() | atom(),
          capacity: non_neg_integer(),
          seq: non_neg_integer()
        }

  defstruct [:events, :spans, :capacity, seq: 0]

  @doc "The tables are made here, and belong to the process that calls this."
  @spec new(Options.t()) :: t()
  def new(%Options{} = options) do
    %__MODULE__{
      events: table(Options.name(options, :Records)),
      spans: table(Options.name(options, :Spans)),
      capacity: options.history
    }
  end

  defp table(name), do: :ets.new(name, [:named_table, :ordered_set, :protected])

  @doc "Keep these, and let go of the oldest that there is no longer room for."
  @spec add(t(), [Event.t()], [Span.t()]) :: t()
  def add(%__MODULE__{capacity: 0} = history, _events, _spans), do: history

  def add(%__MODULE__{} = history, events, spans) do
    history
    |> keep(history.events, events)
    |> keep(history.spans, spans)
  end

  defp keep(history, _table, []), do: history

  defp keep(history, table, items) do
    {rows, seq} =
      Enum.map_reduce(items, history.seq, fn item, seq -> {{seq + 1, item}, seq + 1} end)

    :ets.insert(table, rows)
    trim(table, :ets.info(table, :size) - history.capacity)
    %{history | seq: seq}
  end

  defp trim(_table, over) when over <= 0, do: :ok

  defp trim(table, over) do
    :ets.delete(table, :ets.first(table))
    trim(table, over - 1)
  end

  @doc "The records kept by the collector of this name, oldest first."
  @spec events(Options.t() | atom()) :: [Event.t()]
  def events(name), do: read(Options.name(name, :Records))

  @doc "The spans kept by the collector of this name, oldest first."
  @spec spans(Options.t() | atom()) :: [Span.t()]
  def spans(name), do: read(Options.name(name, :Spans))

  defp read(table) do
    for {_seq, item} <- :ets.tab2list(table), do: item
  rescue
    # No collector of that name is running.
    ArgumentError -> []
  end
end
