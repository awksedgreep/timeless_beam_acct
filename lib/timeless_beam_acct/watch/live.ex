defmodule TimelessBeamAcct.Watch.Live do
  @moduledoc """
  Now: what the collector in a node last read, asked of the node.

  Nothing is read of the node here but what its collector has read
  already. A reading is as old as the collector's interval, which is ten
  seconds unless it was told otherwise, and it costs the node an answer.

  The node may be this one.
  """

  alias TimelessBeamAcct.{Clock, Human}
  alias TimelessBeamAcct.Watch.Data

  @type t :: %__MODULE__{node: node(), name: atom(), timeout: pos_integer()}

  @enforce_keys [:node]
  defstruct [:node, name: TimelessBeamAcct, timeout: 5_000]

  @doc """
  What the collector says of itself, or `{:error, why}` if the node has
  none that is running.
  """
  @spec status(t()) :: {:ok, map()} | {:error, String.t()}
  def status(%__MODULE__{} = live) do
    case call(live, TimelessBeamAcct, :status, [live.name]) do
      {:ok, %{} = status} ->
        {:ok, status}

      {:ok, nil} ->
        {:error, none(live)}

      {:error, :undefined} ->
        {:error, none(live)}

      {:error, why} ->
        {:error, "#{live.node} did not answer: #{inspect(why, limit: 5)}"}
    end
  end

  defp none(live) do
    "#{live.node} has no collector running: " <>
      "`mix timeless_beam_acct.attach #{live.node}` puts one into it"
  end

  @doc """
  When the collector last read the node and its processes: what says
  whether there is anything new to ask for. `nil` if it cannot be asked.
  """
  @spec stamp(t()) :: term()
  def stamp(%__MODULE__{} = live) do
    case call(live, TimelessBeamAcct, :status, [live.name]) do
      {:ok, %{} = status} -> {get_in(status, [:vm, :at]), get_in(status, [:sweep, :at])}
      _ -> nil
    end
  end

  @doc """
  The node as its collector last read it: when, the series of each
  metric, and the processes the collector has.

  A metric that was last read more than `within` seconds ago is left out:
  it is of something that is no longer read.

  `which` processes is what `TimelessBeamAcct.snapshot/2` is told: the
  first few, or those of a group. A node may have a hundred thousand, and
  is not asked for all of them.
  """
  @spec read(t(), float(), keyword()) ::
          {:ok, %{at: float(), series: Data.series(), processes: [Data.process()]}}
          | {:error, String.t()}
  def read(%__MODULE__{} = live, within, which \\ []) do
    snapshot =
      case call(live, TimelessBeamAcct, :snapshot, [live.name, which]) do
        # A collector of before it could be asked for some of them.
        {:error, :undefined} ->
          call(live, TimelessBeamAcct, :snapshot, [live.name])

        answer ->
          answer
      end

    case snapshot do
      {:ok, %{} = snapshot} ->
        rows =
          case call(live, TimelessBeamAcct, :reading, [live.name]) do
            {:ok, rows} when is_list(rows) -> rows
            # A collector of before there was one to ask for.
            _ -> []
          end

        {at, samples} =
          case rows do
            [] ->
              {snapshot[:ts] || Clock.now(), []}

            rows ->
              latest = rows |> Enum.map(&elem(&1, 1)) |> Enum.max()

              {latest,
               for {metric, at, series} <- rows,
                   latest - at <= within,
                   {labels, value} <- series,
                   is_number(value) do
                 {metric, labels, value}
               end}
          end

        {:ok,
         %{
           at: at / 1,
           series: Data.series(samples),
           processes: Data.from_snapshot(snapshot[:processes] || [])
         }}

      {:ok, other} ->
        {:error, "#{live.node} answered #{inspect(other, limit: 5)}"}

      {:error, why} ->
        {:error, "#{live.node} did not answer: #{inspect(why, limit: 5)}"}
    end
  end

  @doc """
  What there is to say of a process that is running, asked of the node:
  `nil` if it is not.
  """
  @spec describe(t(), String.t()) :: [{String.t(), String.t()}] | nil
  def describe(%__MODULE__{} = live, pid) do
    items = [
      :current_function,
      :status,
      :message_queue_len,
      :memory,
      :links,
      :current_stacktrace
    ]

    with {:ok, pid} when is_pid(pid) <-
           call(live, :erlang, :list_to_pid, [String.to_charlist(pid)]),
         {:ok, info} when is_list(info) <- call(live, :erlang, :process_info, [pid, items]) do
      {module, function, arity} = info[:current_function]

      stack =
        for {module, function, arity, _where} <- Enum.take(info[:current_stacktrace] || [], 6),
            do: {"", "  " <> mfa(module, function, arity)}

      [
        {"running", mfa(module, function, arity)},
        {"status", to_string(info[:status])},
        {"queue", "#{info[:message_queue_len]} waiting"},
        {"memory", Human.bytes(info[:memory] || 0)},
        {"links", "#{length(info[:links] || [])}"}
      ] ++
        case stack do
          [_, _ | _] -> [{"stack", stack |> hd() |> elem(1) |> String.trim()} | tl(stack)]
          _ -> []
        end ++ [{"ended", "It is still running."}]
    else
      _ -> nil
    end
  end

  defp mfa(module, function, arity) when is_list(arity), do: mfa(module, function, length(arity))
  defp mfa(module, function, arity), do: Exception.format_mfa(module, function, arity)

  @doc "The records the collector keeps in memory, oldest first."
  @spec records(t()) :: [TimelessBeamAcct.Event.t()]
  def records(%__MODULE__{} = live) do
    case call(live, TimelessBeamAcct, :records, [[name: live.name, kind: :any]]) do
      {:ok, records} when is_list(records) -> records
      _ -> []
    end
  end

  @doc "The spans the collector keeps in memory, oldest first."
  @spec spans(t()) :: [TimelessBeamAcct.Span.t()]
  def spans(%__MODULE__{} = live) do
    case call(live, TimelessBeamAcct, :spans, [live.name]) do
      {:ok, spans} when is_list(spans) -> spans
      _ -> []
    end
  end

  defp call(%__MODULE__{node: node, timeout: timeout}, module, function, args) do
    {:ok, :erpc.call(node, module, function, args, timeout)}
  catch
    # What the node has no such function for: it has no collector, or one
    # of before there was that to ask.
    :error, {:exception, :undef, _stack} -> {:error, :undefined}
    :error, {:exception, %UndefinedFunctionError{}, _stack} -> {:error, :undefined}
    :error, {:exception, reason, _stack} -> {:error, {:exception, reason}}
    :error, {:erpc, reason} -> {:error, reason}
    kind, reason -> {:error, {kind, reason}}
  end
end
