defmodule TimelessBeamAcct.Watch.Memory do
  @moduledoc """
  What a collector keeps in memory, as a store: the last few thousand
  processes to end, and the jobs they were.

  It holds no moment but now. It is what is read of a node whose
  collector writes to nothing that can be asked.
  """

  @behaviour TimelessBeamAcct.Watch.Store

  alias TimelessBeamAcct.Watch.{Live, Store}

  @type t :: %__MODULE__{live: Live.t()}

  @enforce_keys [:live]
  defstruct [:live]

  @impl true
  def range(%__MODULE__{} = store), do: {nil, store}

  @impl true
  def at(%__MODULE__{}, _at, _within), do: {:ok, %{}}

  @impl true
  def history(%__MODULE__{}, _metric, _key, _want, _from, _to), do: []

  @impl true
  def spacing(%__MODULE__{}, _until), do: {nil, nil}

  @impl true
  def timeline(%__MODULE__{}, _from, _to), do: {[], 10.0}

  @impl true
  def incidents(%__MODULE__{} = store, from, to) do
    for exit <- ended(store),
        exit.at >= from and exit.at <= to,
        exit.level in ["error", "warning"],
        do: %{at: exit.at, error: exit.level == "error"}
  end

  @impl true
  def exits(%__MODULE__{} = store, %{until: until, span: span, limit: limit}, wanted) do
    {:ok,
     store
     |> ended()
     |> Enum.filter(&(&1.at <= until and &1.at >= until - span and wanted.(&1)))
     |> Enum.reverse()
     |> Enum.take(limit)}
  end

  @impl true
  def record(%__MODULE__{} = store, group, pid, from) do
    Enum.find(ended(store), &(&1.name == group and &1.pid == pid and &1.at >= from))
  end

  @impl true
  def jobs(%__MODULE__{live: live}, %{until: until, span: span, limit: limit}, width, wanted) do
    {:ok,
     live
     |> Live.spans()
     |> Store.jobs_of(width)
     |> Enum.filter(&(&1.started <= until and &1.started >= until - span and wanted.(&1)))
     |> Enum.take(limit)}
  end

  # The processes that ended, oldest first.
  defp ended(%__MODULE__{live: live}) do
    for %{ts_us: ts_us, level: level, fields: %{"kind" => "exit"} = fields} <- Live.records(live),
        do: Store.exit(ts_us / 1_000_000, level, fields)
  end
end
