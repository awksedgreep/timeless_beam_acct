defmodule TimelessBeamAcct.Watch.Store do
  @moduledoc """
  Where the moments that are not now are read from.

  A store is read and never written. The collector that fills it goes on
  filling it, and what it has written since the last look is there at the
  next one.

  Two things are a store: the Timeless planes, asked over HTTP
  (`TimelessBeamAcct.Watch.Planes`), which hold what a collector has
  written for as long as they were told to keep it; and what the collector
  keeps in memory (`TimelessBeamAcct.Watch.Memory`), which is the last
  few thousand processes to end and no other moment than now.
  """

  alias TimelessBeamAcct.{Human, Report, Span}
  alias TimelessBeamAcct.Watch.Data

  @typedoc "A process that ended."
  @type exit :: %{
          at: float(),
          name: String.t(),
          pid: String.t(),
          app: String.t(),
          status: String.t(),
          level: String.t(),
          elapsed: number() | nil,
          whole: boolean(),
          reductions: number() | nil,
          peak_memory: number() | nil,
          process: String.t(),
          fields: map()
        }

  @typedoc "A job: the processes of one trace."
  @type job :: %{
          started: float(),
          duration: float(),
          reductions: number() | nil,
          processes: non_neg_integer(),
          failed: non_neg_integer(),
          app: String.t(),
          name: String.t(),
          tree: [String.t()],
          running: boolean()
        }

  @typedoc "A process that ended badly: by raising, or by being killed."
  @type incident :: %{at: float(), error: boolean()}

  @typedoc "How far to look, and for how many."
  @type reach :: %{until: float(), span: float(), limit: pos_integer()}

  @type t :: struct()

  @doc "The first and last moments the store holds samples of, and the store."
  @callback range(t()) :: {{float(), float()} | nil, t()}

  @doc """
  The store at one moment: for each series, its last sample in the
  `within` seconds up to `at`. A process that had ended by then has none,
  and is not there.
  """
  @callback at(t(), at :: float(), within :: float()) ::
              {:ok, Data.series()} | {:error, String.t()}

  @doc "One series over a stretch of time: `{epoch seconds, value}`."
  @callback history(
              t(),
              metric :: String.t(),
              key :: String.t(),
              want :: String.t(),
              float(),
              float()
            ) ::
              [{float(), float()}]

  @doc """
  How far apart the store's samples are around a moment, in seconds: of
  the node, and of its processes.
  """
  @callback spacing(t(), until :: float()) :: {float() | nil, float() | nil}

  @doc """
  How busy the schedulers were over a stretch of time, and how far apart
  the figures are.
  """
  @callback timeline(t(), from :: float(), to :: float()) :: {[{float(), float()}], float()}

  @doc """
  The processes that ended badly over a stretch of time that is drawn in
  so many parts: enough of them that every part in which one ended has
  one, and the store, which may have kept what it found out.
  """
  @callback incidents(t(), from :: float(), to :: float(), parts :: pos_integer()) ::
              {[incident()], t()}

  @doc "The processes that ended within reach and are wanted, the last to end first."
  @callback exits(t(), reach(), wanted :: (exit() -> boolean())) ::
              {:ok, [exit()]} | {:error, String.t()}

  @doc """
  The record of how a process ended, if it has: the first of that group
  and pid to end after `from`.
  """
  @callback record(t(), group :: String.t(), pid :: String.t(), from :: float()) :: exit() | nil

  @doc """
  The jobs with a process that started within reach, and that are wanted,
  the last to start first. A job is more than one process.
  """
  @callback jobs(t(), reach(), width :: non_neg_integer(), wanted :: (job() -> boolean())) ::
              {:ok, [job()]} | {:error, String.t()}

  for {name, arity} <-
        [range: 1, at: 3, history: 6, spacing: 2, timeline: 3] ++
          [incidents: 4, exits: 3, record: 4, jobs: 4] do
    args = Macro.generate_arguments(arity - 1, __MODULE__)

    @doc false
    def unquote(name)(%module{} = store, unquote_splicing(args)),
      do: module.unquote(name)(store, unquote_splicing(args))
  end

  ## What both stores make of what they read

  @doc "A record of a process that ended, as a row of the screen."
  @spec exit(float(), String.t() | atom(), map()) :: exit()
  def exit(at, level, fields) do
    group = text(fields["service"])

    {elapsed, whole} =
      case fields do
        %{"elapsed_seconds" => seconds} when is_number(seconds) -> {seconds, true}
        %{"seen_seconds" => seconds} when is_number(seconds) -> {seconds, false}
        _ -> {nil, true}
      end

    %{
      at: at,
      name: group,
      pid: text(fields["pid"]),
      app: text(fields["app"]),
      status: text(fields["status"]),
      level: to_string(level),
      elapsed: elapsed,
      whole: whole,
      reductions: number(fields["reductions"]),
      peak_memory: number(fields["peak_memory_bytes"]),
      process:
        case fields["name"] do
          name when is_binary(name) and name != "" and name != group -> "#{group} (#{name})"
          _ -> group
        end,
      fields: fields
    }
  end

  @doc """
  The jobs among spans, the last to start first: the traces of more than
  one process.
  """
  @spec jobs_of([Span.t()], non_neg_integer()) :: [job()]
  def jobs_of(spans, width) do
    spans
    |> Enum.group_by(& &1.trace_id)
    |> Enum.filter(&match?({_trace, [_, _ | _]}, &1))
    |> Enum.map(fn {_trace, all} -> job(all, width) end)
    |> Enum.sort_by(& &1.started, :desc)
  end

  @doc "One job, from all of its spans."
  @spec job([Span.t()], non_neg_integer()) :: job()
  def job(all, width) do
    start = all |> Enum.map(& &1.start_ns) |> Enum.min()
    stop = all |> Enum.map(&(&1.start_ns + &1.duration_ns)) |> Enum.max()
    root = all |> Report.roots() |> List.first()

    reductions =
      for %Span{attributes: %{"process.reductions" => reductions}} <- all,
          is_number(reductions),
          do: reductions

    %{
      started: start / 1_000_000_000,
      duration: (stop - start) / 1_000_000_000,
      reductions: if(reductions == [], do: nil, else: Enum.sum(reductions)),
      processes: length(all),
      failed: Enum.count(all, &(&1.ok == false)),
      app: (root && root.service) || "",
      name: (root && root.name) || "",
      tree: Report.tree_lines(all, width, 200),
      running: false
    }
  end

  @doc """
  The gap that half of the samples are no further apart than: a tick that
  was missed, or a collector that was stopped and started, is a gap and
  not the spacing. `nil` of fewer than three samples.
  """
  @spec spacing_of([{float(), float()}]) :: float() | nil
  def spacing_of(samples) do
    gaps =
      samples
      |> Enum.map(&elem(&1, 0))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)
      |> Enum.filter(&(&1 > 0))
      |> Enum.sort()

    if length(gaps) >= 2, do: Enum.at(gaps, div(length(gaps), 2))
  end

  @doc "`3m00s ago`, `2h05m ago`: how far back a moment is."
  @spec ago(number(), number()) :: String.t()
  def ago(now, at), do: Human.duration(max(now - at, 0)) <> " ago"

  defp text(value) when is_binary(value), do: value
  defp text(nil), do: ""
  defp text(value), do: to_string(value)

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil
end
