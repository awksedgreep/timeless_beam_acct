defmodule TimelessBeamAcct.Watch.Planes do
  @moduledoc """
  The Timeless planes, read over HTTP: what a collector with the `:http`
  sink has written, for as long as the planes were told to keep it.

  Each question is one request, or a few, and the planes do the looking:
  a moment is every series of the node as of that moment, in one answer.

  ## Options

  | option | | |
  |---|---|---|
  | `:metrics_url` | | the metrics plane |
  | `:logs_url` | | the logs plane, which has the records |
  | `:traces_url` | | the traces plane, which has the jobs |
  | `:defaults` | `false` | whether a plane that is not said is where a collector writes unless told: port 8428, 9428, or 10428 of this host |
  | `:token` | | a bearer token, for all three |
  | `:metrics_token`, `:logs_token`, `:traces_token` | | one for each, in place of it |
  | `:node` | the only one there is | the node whose series are read |
  | `:host` | | the host, where nodes of one name run on several |
  | `:timeout` | `5000` | milliseconds to wait for an answer |

  A plane that is not said, and is not where a collector would write, is
  not read: what it would have had is said to be missing.
  """

  @behaviour TimelessBeamAcct.Watch.Store

  alias TimelessBeamAcct.{Http, Span}
  alias TimelessBeamAcct.Watch.{Data, Store}

  @type t :: %__MODULE__{
          metrics: String.t() | nil,
          logs: String.t() | nil,
          traces: String.t() | nil,
          tokens: %{atom() => String.t() | nil},
          node: String.t() | nil,
          host: String.t() | nil,
          timeout: pos_integer(),
          first: {float(), integer()} | nil
        }

  defstruct metrics: nil,
            logs: nil,
            traces: nil,
            tokens: %{},
            node: nil,
            host: nil,
            timeout: 5_000,
            # The first moment held, and when that was found out.
            first: nil,
            # The most badly ended processes read at once for a timeline;
            # the parts of it that lie further back are asked about one
            # at a time, and kept.
            most_incidents: 500,
            # What was found out of parts of a timeline the last answers
            # did not reach: `{level, from, to}` to an incident, or nil.
            probed: %{}

  # An answer may be this long. A moment of a node with two hundred
  # groups and two hundred processes is half a megabyte.
  @keep 64 * 1024 * 1024
  # The most records read at once, and the most spans: what the planes
  # give in one answer.
  @records 1000
  @spans 100
  # How often the first moment held is looked for again: it moves when the
  # planes let go of what is old.
  @first_for 300
  # The most jobs whose spans are all read.
  @jobs 30

  @doc """
  A store, from what was said of where it is. `{:error, why}` if something
  said is not understood.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(opts) do
    known =
      [:metrics_url, :logs_url, :traces_url, :token, :metrics_token, :logs_token] ++
        [:traces_token, :node, :host, :timeout, :defaults]

    case Keyword.keys(opts) -- known do
      [] ->
        default = %__MODULE__{}
        token = opts[:token]

        unless_told =
          if opts[:defaults],
            do:
              %{metrics: "http://127.0.0.1:8428", logs: "http://127.0.0.1:9428"}
              |> Map.put(:traces, "http://127.0.0.1:10428"),
            else: %{metrics: nil, logs: nil, traces: nil}

        {:ok,
         %__MODULE__{
           metrics: base(opts[:metrics_url] || unless_told.metrics),
           logs: base(opts[:logs_url] || unless_told.logs),
           traces: base(opts[:traces_url] || unless_told.traces),
           tokens: %{
             metrics: opts[:metrics_token] || token,
             logs: opts[:logs_token] || token,
             traces: opts[:traces_token] || token
           },
           node: opts[:node],
           host: opts[:host],
           timeout: opts[:timeout] || default.timeout
         }}

      [unknown | _] ->
        {:error, "#{inspect(unknown)} is not something a store is told"}
    end
  end

  defp base(nil), do: nil
  defp base(url), do: String.trim_trailing(url, "/")

  @doc """
  Find out that the metrics plane answers, and which node it is asked
  about, if that was not said: the only one it has series of.
  """
  @spec reach(t()) :: {:ok, t()} | {:error, String.t()}
  def reach(%__MODULE__{node: node} = store) when is_binary(node) do
    with {:ok, _} <- nodes(store), do: {:ok, store}
  end

  def reach(%__MODULE__{} = store) do
    case nodes(store) do
      {:ok, [node]} ->
        {:ok, %{store | node: node}}

      {:ok, []} ->
        {:error, "#{store.metrics} has nothing a collector wrote: no series of beam_vm_processes"}

      {:ok, nodes} ->
        {:error,
         "#{store.metrics} has these nodes, and one is to be said with --node: " <>
           Enum.join(nodes, ", ")}

      {:error, why} ->
        {:error, why}
    end
  end

  defp nodes(store) do
    case get(store, :metrics, "/api/v1/label/node/values", metric: "beam_vm_processes") do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, %{"data" => nodes}} when is_list(nodes) -> {:ok, nodes}
          _ -> {:error, "#{store.metrics} answered what is not a list of nodes"}
        end

      {:error, why} ->
        {:error, why}
    end
  end

  ## The store

  @impl true
  def range(%__MODULE__{} = store) do
    last =
      with {:ok, body} <-
             get(store, :metrics, "/api/v1/query", [metric: "beam_vm_processes"] ++ who(store)),
           {:ok, answer} <- JSON.decode(body) do
        answer
        |> latest()
        |> Enum.map(& &1["timestamp"])
        |> Enum.filter(&is_number/1)
        |> Enum.max(fn -> nil end)
      else
        _ -> nil
      end

    case last do
      nil ->
        {nil, store}

      last ->
        store = first(store, last)
        {first, _found} = store.first
        {{min(first, last / 1), last / 1}, store}
    end
  end

  defp latest(%{"data" => series}) when is_list(series), do: series
  defp latest(%{"timestamp" => _} = one), do: [one]
  defp latest(_answer), do: []

  # The first moment: the stretch the plane holds is counted in a
  # thousand parts, and the first part with a sample in it is read.
  defp first(%__MODULE__{first: {_first, found}} = store, last) when last - found < @first_for,
    do: store

  defp first(store, last) do
    oldest =
      with {:ok, body} <- get(store, :metrics, "/select/metrics/stats", []),
           {:ok, %{"oldest_timestamp_seconds" => oldest}} when is_number(oldest) and oldest > 0 <-
             JSON.decode(body) do
        oldest
      else
        _ -> last - 7 * 86_400
      end

    step = max(div(trunc(last - oldest), 1000), 60)

    counted =
      get(
        store,
        :metrics,
        "/api/v1/query_range",
        [
          metric: "beam_vm_processes",
          start: oldest - step,
          end: last,
          step: step,
          aggregate: "count"
        ] ++
          who(store)
      )

    first =
      with {:ok, body} <- counted,
           {:ok, %{"series" => series}} <- JSON.decode(body),
           [bucket | _] <-
             series
             |> Enum.flat_map(&(&1["data"] || []))
             |> Enum.filter(&match?([_, count] when count > 0, &1))
             |> Enum.map(&hd/1)
             |> Enum.sort(),
           [{at, _} | _] <- history(store, "beam_vm_processes", nil, nil, bucket, bucket + step) do
        at
      else
        _ -> last / 1
      end

    %{store | first: {first, trunc(last)}}
  end

  # A moment is asked for a metric at a time, by name, and the questions
  # are asked together. One question for all of them, with a pattern for
  # the name, costs the plane a walk of its whole catalog
  # (timeless-libsql #95): a quarter of a second at fifty thousand series,
  # where a name is a lookup.
  @at_once 8

  @impl true
  def at(%__MODULE__{} = store, at, within, tiers) do
    labels = for {key, value} <- who(store), do: ~s[#{key}="#{escape(value)}"]

    answers =
      tiers
      |> Data.metrics()
      |> Task.async_stream(
        fn metric ->
          get(store, :metrics, "/api/v1/query",
            query: metric <> "{" <> Enum.join(labels, ",") <> "}",
            time: trunc(at),
            lookback_delta: "#{max(ceil(within), 1)}s"
          )
        end,
        max_concurrency: @at_once,
        timeout: store.timeout + 1000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, answer} -> answer
        {:exit, _} -> {:error, "#{store.metrics}: timed out"}
      end)

    case Enum.find(answers, &match?({:error, _}, &1)) do
      {:error, why} ->
        {:error, why}

      nil ->
        answers
        |> Enum.reduce_while({:ok, []}, fn {:ok, body}, {:ok, samples} ->
          case JSON.decode(body) do
            {:ok, %{"status" => "success", "data" => %{"result" => result}}} ->
              more =
                for %{"metric" => %{"__name__" => name} = labels, "value" => [_at, value]} <-
                      result,
                    value = number(value),
                    do: {name, Map.delete(labels, "__name__"), value}

              {:cont, {:ok, more ++ samples}}

            _ ->
              {:halt, {:error, "#{store.metrics} answered what is not the series of a moment"}}
          end
        end)
        |> case do
          {:ok, samples} -> {:ok, Data.series(samples)}
          error -> error
        end
    end
  end

  defp escape(value), do: value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  @impl true
  def history(%__MODULE__{} = store, metric, key, want, from, to) do
    label = if key, do: [{key, want}], else: []

    asked =
      get(
        store,
        :metrics,
        "/api/v1/export",
        [metric: metric, start: trunc(Float.floor(from / 1)), end: trunc(Float.ceil(to / 1))] ++
          label ++ who(store)
      )

    case asked do
      {:ok, body} ->
        body
        |> lines()
        |> Enum.flat_map(fn
          %{"timestamps" => stamps, "values" => values} ->
            for {ms, value} <- Enum.zip(stamps, values),
                is_number(value),
                do: {ms / 1000, value / 1}

          _ ->
            []
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @impl true
  def spacing(%__MODULE__{} = store, until) do
    of = fn metric ->
      Enum.find_value([300.0, 4 * 3600.0], fn back ->
        store |> history(metric, nil, nil, until - back, until) |> Store.spacing_of()
      end)
    end

    {of.("beam_vm_processes"), of.("beam_acct_processes")}
  end

  @impl true
  def timeline(%__MODULE__{} = store, from, to) do
    span = to - from
    metric = "beam_vm_scheduler_util_pct"

    resolution =
      cond do
        span <= 2 * 3600 -> 0
        span <= 48 * 3600 -> 300
        true -> 3600
      end

    ranged =
      if resolution > 0 do
        asked =
          get(
            store,
            :metrics,
            "/api/v1/query_range",
            [metric: metric, scheduler: "all", start: trunc(from), end: trunc(Float.ceil(to / 1))] ++
              [step: resolution, aggregate: "max"] ++ who(store)
          )

        with {:ok, body} <- asked,
             {:ok, %{"series" => [%{"data" => [_ | _] = points} | _]}} <- JSON.decode(body) do
          for [at, value] <- points, is_number(value), do: {at / 1, value / 1}
        else
          _ -> []
        end
      else
        []
      end

    case ranged do
      [] ->
        {history(store, metric, "scheduler", "all", from, to),
         elem(spacing(store, to), 0) || 10.0}

      points ->
        {points, resolution / 1}
    end
  end

  @impl true
  def incidents(%__MODULE__{} = store, from, to, parts) do
    parts = max(parts, 1)
    each = (to - from) / parts

    {found, probes} =
      Enum.reduce([{"error", true}, {"warning", false}], {[], []}, fn {level, error},
                                                                      {found, probes} ->
        rows = records(store, [level: level, limit: store.most_incidents], from, to)

        incidents =
          for row <- rows,
              row["kind"] == "exit",
              ours?(store, row),
              at = moment(row["_time"]),
              do: %{at: at, error: error}

        # A busy node ends more processes badly in a stretch than are read
        # at once, and the answer reaches back only so far. The parts of
        # the stretch before that are asked about one at a time, for one
        # process each: a mark says that one ended in that part, and not
        # how many or when, so what is found is put in the middle of it.
        reached =
          if length(rows) >= store.most_incidents,
            do: incidents |> Enum.map(& &1.at) |> Enum.min(fn -> to end),
            else: from

        probes =
          probes ++
            for part <- 0..(parts - 1),
                start = from + each * part,
                stop = start + each,
                stop <= reached,
                do:
                  {level, error, trunc(Float.floor(start)), trunc(Float.ceil(stop)),
                   start + each / 2}

        {found ++ incidents, probes}
      end)

    probed =
      probes
      |> Enum.reject(fn {level, _, start, stop, _} ->
        Map.has_key?(store.probed, {level, start, stop})
      end)
      |> Task.async_stream(
        fn {level, error, start, stop, middle} ->
          # Asked by whole seconds, which reach a little past the part:
          # what is found is of the part only if it is within it.
          found =
            store
            |> records([level: level, limit: 5, order: "desc"], start, stop)
            |> Enum.any?(fn row ->
              row["kind"] == "exit" and ours?(store, row) and
                case moment(row["_time"]) do
                  at when is_number(at) -> at >= middle - each / 2 and at <= middle + each / 2
                  _ -> false
                end
            end)

          {{level, start, stop}, if(found, do: %{at: middle, error: error})}
        end,
        max_concurrency: 8,
        timeout: store.timeout + 1000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {key, incident}} -> [{key, incident}]
        _ -> []
      end)
      |> Map.new()

    # What was found out of a part is kept while the part is in the
    # stretch: a part of the past does not change.
    kept =
      store.probed
      |> Map.merge(probed)
      |> Map.filter(fn {{_level, start, stop}, _} -> stop >= from and start <= to end)

    marked =
      for {level, _error, start, stop, _middle} <- probes,
          incident = kept[{level, start, stop}],
          do: incident

    {Enum.sort_by(found ++ marked, & &1.at), %{store | probed: kept}}
  end

  @impl true
  def recordings(%__MODULE__{} = store, from, to) do
    # Of every node: a recording is found by when it began, whoever it was of.
    asked =
      get(
        store,
        :logs,
        "/select/logsql/query",
        bounds(from, to) ++ [service: "recording", limit: @records, order: "desc"] ++ host(store)
      )

    case asked do
      {:ok, body} ->
        {:ok,
         body
         |> lines()
         |> Enum.flat_map(fn row ->
           case moment(row["_time"]) do
             nil -> []
             at -> [{at, Map.drop(row, ["_msg", "_time"])}]
           end
         end)
         |> Store.recordings_of()}

      {:error, why} ->
        {:error, why}
    end
  end

  @impl true
  def exits(%__MODULE__{} = store, %{until: until, span: span, limit: limit}, wanted) do
    # What is wanted is decided as the store is read, and not after: a
    # busy node ends hundreds of processes a second, and the one that is
    # looked for is seldom among the last few.
    Enum.reduce_while(0..9, {:ok, []}, fn page, {:ok, found} ->
      case get(
             store,
             :logs,
             "/select/logsql/query",
             bounds(until - span, until) ++
               [limit: @records, offset: page * @records, order: "desc"] ++ host(store)
           ) do
        {:ok, body} ->
          rows = lines(body)

          found =
            found ++
              for row <- rows,
                  row["kind"] == "exit",
                  ours?(store, row),
                  exit = exit_of(row),
                  wanted.(exit),
                  do: exit

          if length(found) >= limit or length(rows) < @records,
            do: {:halt, {:ok, Enum.take(found, limit)}},
            else: {:cont, {:ok, found}}

        {:error, why} ->
          {:halt, {:error, why}}
      end
    end)
  end

  @impl true
  def record(%__MODULE__{} = store, group, pid, from) do
    store
    |> records([service: group, limit: @records, order: "asc"], from, from + 7 * 86_400.0)
    |> Enum.find_value(fn row ->
      if row["kind"] == "exit" and row["pid"] == pid and ours?(store, row), do: exit_of(row)
    end)
  end

  @impl true
  def jobs(%__MODULE__{} = store, %{until: until, span: span, limit: limit}, width, wanted) do
    since = trunc((until - span) * 1_000_000_000)
    before = trunc(until * 1_000_000_000)

    # The latest to start are the ones wanted. The last few hundred spans
    # are read, the traces among them that have more than one are jobs,
    # and the spans of those are read in full.
    pages =
      0..5
      |> Task.async_stream(
        fn page ->
          get(store, :traces, "/select/timeless/api/spans",
            since: since,
            until: before,
            limit: @spans,
            offset: page * @spans,
            order: "desc"
          )
        end,
        max_concurrency: 3,
        timeout: store.timeout + 1000
      )
      |> Enum.map(fn {:ok, answer} -> answer end)

    case Enum.find(pages, &match?({:error, _}, &1)) do
      {:error, why} ->
        {:error, why}

      nil ->
        seen =
          for {:ok, body} <- pages,
              {:ok, %{"entries" => entries}} <- [JSON.decode(body)],
              entry <- entries,
              ours?(store, entry),
              do: entry

        traces =
          seen
          |> Enum.group_by(& &1["trace_id"])
          |> Enum.filter(&match?({_trace, [_, _ | _]}, &1))
          |> Enum.map(fn {trace, spans} ->
            {spans |> Enum.map(& &1["start_time"]) |> Enum.min(), trace}
          end)
          |> Enum.sort(:desc)
          |> Enum.take(min(limit, @jobs))

        jobs =
          traces
          |> Task.async_stream(
            fn {_start, trace} ->
              get(store, :traces, "/select/timeless/api/traces/#{trace}", [])
            end,
            max_concurrency: 4,
            timeout: store.timeout + 1000
          )
          |> Enum.flat_map(fn
            {:ok, {:ok, body}} ->
              case JSON.decode(body) do
                {:ok, %{"spans" => [_ | _] = spans}} ->
                  [spans |> Enum.flat_map(&span_of/1) |> Store.job(width)]

                _ ->
                  []
              end

            _ ->
              []
          end)
          |> Enum.filter(wanted)

        {:ok, jobs}
    end
  end

  ## What the planes say, as what the screen shows

  defp exit_of(row) do
    case moment(row["_time"]) do
      nil -> nil
      at -> Store.exit(at, row["level"] || "info", Map.drop(row, ["_msg", "_time", "level"]))
    end
  end

  defp span_of(%{"trace_id" => trace, "span_id" => id, "start_time" => start} = span) do
    with {:ok, trace} <- Base.decode16(trace, case: :mixed),
         {:ok, id} <- Base.decode16(id, case: :mixed) do
      parent =
        case span["parent_span_id"] do
          text when is_binary(text) and text != "" ->
            case Base.decode16(text, case: :mixed) do
              {:ok, parent} -> parent
              :error -> nil
            end

          _ ->
            nil
        end

      [
        %Span{
          trace_id: trace,
          span_id: id,
          parent_span_id: parent,
          name: span["name"] || "",
          service: get_in(span, ["resource", "service.name"]) || "",
          ok:
            case span["status"] do
              "ok" -> true
              "error" -> false
              _ -> nil
            end,
          ending: span["status_message"] || "",
          start_ns: start,
          duration_ns: span["duration_ns"] || 0,
          attributes: span["attributes"] || %{}
        }
      ]
    else
      _ -> []
    end
  end

  defp span_of(_span), do: []

  # Whether a record, or a span, is of the node that is looked at.
  defp ours?(%__MODULE__{node: nil}, _row), do: true

  defp ours?(%__MODULE__{node: node}, row) do
    case row do
      %{"node" => other} -> other == node
      %{"resource" => %{"service.instance.id" => other}} -> other == node
      _ -> true
    end
  end

  defp records(store, params, from, to) do
    case get(store, :logs, "/select/logsql/query", bounds(from, to) ++ params ++ host(store)) do
      {:ok, body} -> lines(body)
      {:error, _} -> []
    end
  end

  defp bounds(from, to),
    do: [start: trunc(Float.floor(from / 1)), end: trunc(Float.ceil(to / 1))]

  # The labels that say whose series are wanted.
  defp who(%__MODULE__{node: node, host: host}),
    do: for({key, value} <- [node: node, host: host], is_binary(value), do: {key, value})

  defp host(%__MODULE__{host: host}), do: if(is_binary(host), do: [host: host], else: [])

  # One thing to a line.
  defp lines(body) do
    for line <- String.split(body, "\n", trim: true),
        {:ok, %{} = row} <- [JSON.decode(line)],
        do: row
  end

  defp moment(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, moment, _offset} -> DateTime.to_unix(moment, :microsecond) / 1_000_000
      _ -> nil
    end
  end

  defp moment(_text), do: nil

  defp number(value) when is_number(value), do: value / 1

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp number(_value), do: nil

  ## Asking

  defp get(%__MODULE__{} = store, plane, path, params) do
    case Map.fetch!(store, plane) do
      nil -> {:error, "Where the #{plane} plane is was not said: --#{plane}-url."}
      base -> get(store, plane, base, path, params)
    end
  end

  # A plane that is busy with its own upkeep says so, and asks to be asked
  # again. It is, once, after this long.
  @again_ms 500

  defp get(%__MODULE__{} = store, plane, base, path, params, again \\ true) do
    url = base <> path <> query(params)

    headers =
      case store.tokens[plane] do
        token when is_binary(token) and token != "" -> [{"authorization", "Bearer " <> token}]
        _ -> []
      end

    case Http.get(url, headers, store.timeout, keep: @keep) do
      {:ok, status, body} when status in 200..299 ->
        {:ok, body}

      {:ok, status, _body} when again and status in [503, 429] ->
        Process.sleep(@again_ms)
        get(store, plane, base, path, params, false)

      {:ok, status, body} ->
        {:error, "#{base} answered #{status}: #{said(body)}"}

      {:error, reason} ->
        {:error, "#{base}: #{Http.format_error(reason)}"}
    end
  end

  defp query([]), do: ""
  defp query(params), do: "?" <> URI.encode_query(params)

  defp said(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => error} = answer} ->
        [error, answer["message"], answer["reason"]]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(": ")

      _ ->
        body |> String.slice(0, 200) |> String.split() |> Enum.join(" ")
    end
  end
end
