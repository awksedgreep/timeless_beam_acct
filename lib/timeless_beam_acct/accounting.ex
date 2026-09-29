defmodule TimelessBeamAcct.Ended do
  @moduledoc """
  What is known of a process that ended.

  Times are epoch microseconds. `born` says whether `since` is when the
  process started, or only when it was first seen. `figures` are those of
  the last sweep that saw it, and `nil` if none did.
  """

  alias TimelessBeamAcct.Ending

  @type figures :: %{
          reductions: non_neg_integer(),
          memory: non_neg_integer(),
          peak_memory: non_neg_integer(),
          queue: non_neg_integer(),
          at: integer()
        }

  @type place :: %{trace_id: binary(), span_id: binary(), parent_span_id: binary() | nil}

  @type t :: %__MODULE__{
          pid: String.t(),
          group: String.t(),
          name: String.t() | nil,
          path: String.t() | nil,
          app: String.t(),
          parent: String.t() | nil,
          parent_group: String.t() | nil,
          caller: String.t() | nil,
          since: integer(),
          born: boolean(),
          ended: integer(),
          ending: Ending.t(),
          source: :traced | :sampled,
          figures: figures() | nil,
          place: place() | nil
        }

  @enforce_keys [:pid, :group, :since, :ended, :ending, :source]
  defstruct [
    :pid,
    :group,
    :name,
    :path,
    :parent,
    :parent_group,
    :caller,
    :since,
    :ended,
    :ending,
    :source,
    :figures,
    :place,
    app: "none",
    born: false
  ]
end

defmodule TimelessBeamAcct.Accounting do
  @moduledoc """
  One accounting record per process that ended, and one span.

  Records are log entries. Their metadata uses the keys the logs plane
  indexes (`service`, `host`, `path`, `status`), so "every exit of
  `MyApp.Worker`", "everything that ended with `timeout`", and "everything
  started with `MyApp.Worker.init/1`" are index lookups, not scans.

  A span is made from the same `TimelessBeamAcct.Ended` as the record, so
  the two cannot disagree. They are kept twice because they are found
  differently. A record is found by what happened: everything that was
  killed. A span is found by where it happened: everything this request
  started, and in what order.

  ## What the figures are

  The VM says that a process ended, when, and why. It does not say what the
  process had used: by the time anything can ask, there is no process to
  ask. So the times of a record are exact, and its figures are those of the
  last sweep that saw the process alive. They are a floor. A process that
  no sweep saw has a record with no figures.
  """

  alias TimelessBeamAcct.{Ended, Ending, Event, Human, Span}

  @type levels :: %{
          normal: Event.level(),
          abnormal: Event.level(),
          killed: Event.level(),
          crashed: Event.level()
        }

  @doc """
  The record of a process that ended.

  A canvas host element turns red when the host logged an error in the last
  minute, and amber for a warning. So the level of a record decides the
  colour of the host, and `levels` is chosen for that: by default a crash
  is a defect in a program on this node, a kill is someone insisting, and
  a reason of the process's own is how it says what happened to it.
  """
  @spec exit_event(Ended.t(), levels()) :: Event.t()
  def exit_event(%Ended{} = ended, levels) do
    fields =
      %{
        "kind" => "exit",
        "source" => Atom.to_string(ended.source),
        "service" => ended.group,
        "status" => ended.ending.status,
        "pid" => ended.pid,
        "app" => ended.app
      }
      |> put("path", ended.path)
      |> put("name", ended.name)
      |> put("parent", ended.parent)
      |> put("parent_name", ended.parent_group)
      |> put("caller", ended.caller)
      |> put("reason", ended.ending.reason)
      |> put("at", ended.ending.at)
      |> put("crashed", if(ended.ending.class == :crashed, do: true))
      |> put_times(ended)
      |> put_figures(ended)
      |> put_place(ended.place)

    %Event{
      ts_us: ended.ended,
      level: level(ended.ending, levels),
      message: message(ended),
      fields: fields
    }
  end

  @doc "The level of a record, by how the process ended."
  @spec level(Ending.t(), levels()) :: Event.level()
  def level(%Ending{class: :unknown}, _levels), do: :info
  def level(%Ending{class: class}, levels), do: Map.fetch!(levels, class)

  @doc """
  `MyApp.Worker<0.512.0> crashed: RuntimeError after 2.5s, 12.4k reductions, peak memory 2.1 MiB`
  """
  @spec message(Ended.t()) :: String.t()
  def message(%Ended{} = ended) do
    lived = Human.duration(elapsed(ended))
    lived = if ended.born, do: lived, else: "at least " <> lived

    figures =
      case ended.figures do
        nil ->
          ""

        figures ->
          ", #{Human.count(figures.reductions)} reductions, peak memory #{Human.bytes(figures.peak_memory)}"
      end

    "#{ended.name || ended.group}#{ended.pid} #{Ending.words(ended.ending)} after #{lived}#{figures}"
  end

  defp elapsed(%Ended{since: since, ended: ended}), do: max(ended - since, 0) / 1_000_000

  defp put(fields, _key, nil), do: fields
  defp put(fields, key, value), do: Map.put(fields, key, value)

  defp put_times(fields, %Ended{born: true} = ended) do
    fields
    |> Map.put("started", ended.since / 1_000_000)
    |> Map.put("elapsed_seconds", elapsed(ended))
  end

  # It lived longer than it was known of.
  defp put_times(fields, %Ended{born: false} = ended),
    do: Map.put(fields, "seen_seconds", elapsed(ended))

  defp put_figures(fields, %Ended{figures: nil}), do: fields

  defp put_figures(fields, %Ended{figures: figures, ended: ended}) do
    Map.merge(fields, %{
      "reductions" => figures.reductions,
      "memory_bytes" => figures.memory,
      "peak_memory_bytes" => figures.peak_memory,
      "message_queue_len" => figures.queue,
      "figures_age_seconds" => max(ended - figures.at, 0) / 1_000_000
    })
  end

  defp put_place(fields, nil), do: fields

  defp put_place(fields, place) do
    Map.merge(fields, %{
      "trace_id" => Span.hex(place.trace_id),
      "span_id" => Span.hex(place.span_id)
    })
  end

  @doc """
  The span of a process that ended, or `nil` if it was given no place in a
  trace.
  """
  @spec span(Ended.t()) :: Span.t() | nil
  def span(%Ended{place: nil}), do: nil

  def span(%Ended{place: place} = ended) do
    attributes =
      %{
        "process.pid" => ended.pid,
        "process.app" => ended.app,
        "process.exit.status" => ended.ending.status,
        "process.source" => Atom.to_string(ended.source),
        "process.start_known" => ended.born
      }
      |> put("process.parent_pid", ended.parent)
      |> put("process.caller_pid", ended.caller)
      |> put("process.name", ended.name)
      |> put("process.initial_call", ended.path)
      |> put("process.exit.reason", ended.ending.reason)
      |> put("process.exit.at", ended.ending.at)
      |> put("process.reductions", ended.figures && ended.figures.reductions)
      |> put("process.peak_memory_bytes", ended.figures && ended.figures.peak_memory)

    %Span{
      trace_id: place.trace_id,
      span_id: place.span_id,
      parent_span_id: place.parent_span_id,
      name: ended.group,
      service: ended.app,
      ok: Ending.ok?(ended.ending),
      ending: Ending.words(ended.ending),
      start_ns: ended.since * 1000,
      duration_ns: max(ended.ended - ended.since, 0) * 1000,
      attributes: attributes
    }
  end

  @type remark :: %{
          kind: atom(),
          at: integer(),
          pid: String.t(),
          group: String.t(),
          name: String.t() | nil,
          path: String.t() | nil,
          app: String.t(),
          value: number() | nil,
          detail: String.t() | nil
        }

  @doc """
  The record of something the VM remarked on: a garbage collection that
  took long, a queue that grew long, a process held up by a busy port.

  A long queue and a large heap are what a node runs out of memory from,
  and are warnings. The rest are how a node is slow, and are notices.
  """
  @spec remark_event(remark()) :: Event.t()
  def remark_event(%{kind: kind} = remark) do
    {words, unit} = remarked(kind, remark.value, remark.detail)

    fields =
      %{
        "kind" => Atom.to_string(kind),
        "source" => "monitor",
        "service" => remark.group,
        "status" => Atom.to_string(kind),
        "pid" => remark.pid,
        "app" => remark.app
      }
      |> put("name", remark.name)
      |> put("path", remark.path)
      |> put("value", remark.value)
      |> put("unit", unit)
      |> put("detail", remark.detail)

    %Event{
      ts_us: remark.at,
      level: if(kind in [:long_message_queue, :large_heap], do: :warning, else: :notice),
      message: "#{remark.name || remark.group}#{remark.pid} #{words}",
      fields: fields
    }
  end

  defp remarked(:long_gc, ms, _), do: {"took #{duration(ms)} to collect garbage", "ms"}
  defp remarked(:long_schedule, ms, _), do: {"ran for #{duration(ms)} without yielding", "ms"}
  defp remarked(:large_heap, bytes, _), do: {"has a heap of #{size(bytes)}", "bytes"}

  defp remarked(:long_message_queue, count, "cleared"),
    do: {"has worked its queue down#{waiting(count)}", "messages"}

  defp remarked(:long_message_queue, count, _),
    do: {"has a long queue#{waiting(count)}", "messages"}

  defp remarked(:busy_port, _, port), do: {"is held up by a busy port#{named(port)}", nil}

  defp remarked(:busy_dist_port, _, port),
    do: {"is held up by a busy connection to a node#{named(port)}", nil}

  defp remarked(kind, _, _), do: {"#{kind}", nil}

  defp duration(nil), do: "long"
  defp duration(ms), do: Human.duration(ms / 1000)
  defp size(nil), do: "unknown size"
  defp size(bytes), do: Human.bytes(bytes)
  defp waiting(nil), do: ""
  defp waiting(count), do: ": #{Human.count(count)} waiting"
  defp named(nil), do: ""
  defp named(port), do: ", #{port}"
end
