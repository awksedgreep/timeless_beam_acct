defmodule TimelessBeamAcct.Watch.Planes do
  @moduledoc """
  The planes, read over HTTP: what a collector with the `:http` sink has
  written, for as long as the planes were told to keep it. Timeless's
  planes, or VictoriaMetrics, VictoriaLogs, and VictoriaTraces: what is
  asked is asked as either answers it.

  Each question is one request, or a few, and the planes do the looking:
  a moment is every series of the node as of that moment, in one answer.

  | plane | asked in |
  |---|---|
  | metrics | PromQL: `/api/v1/query`, `/api/v1/query_range`, and the values of the `node` label |
  | logs | LogsQL, by POST to `/select/logsql/query`, with the time in the query |
  | traces | Jaeger's: `/select/jaeger/api/traces/<id>`, a trace at a time |

  The jobs are found among the records: every process that ended is a
  record with the trace it was of, and a trace with more than one is a
  job. VictoriaTraces makes a trace findable half a minute after it is
  written; one that is not found yet is looked for a minute further back.

  What the planes hold, and how small (`storage/1`), is of Timeless's
  planes, which count it; of others, nothing is said.

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

  alias TimelessBeamAcct.{Http, Human, Span}
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
    case get(store, :metrics, "/api/v1/label/node/values", "match[]": "beam_vm_processes") do
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
    case last(store) do
      nil ->
        {nil, store}

      last ->
        store = first(store, last)
        {first, _found} = store.first
        {{min(first, last / 1), last / 1}, store}
    end
  end

  # The last sample of the node: looked for in the last five minutes, its
  # own time read from the raw samples, and if there is none there, the
  # last hour of the last week that has one is found and looked in.
  # (`timestamp()` would say it in one question, but not every plane says
  # the sample's time by it: one says the time it was asked at.)
  defp last(store) do
    now = TimelessBeamAcct.Clock.now()

    case latest_in(store, now, 300) do
      nil ->
        hours =
          promql_range(
            store,
            "count_over_time(#{selector(store, "beam_vm_processes")}[3600s])",
            now - 7 * 86_400,
            now,
            3600
          )

        case hours
             |> Enum.flat_map(& &1.values)
             |> Enum.map(&elem(&1, 0))
             |> Enum.max(fn -> nil end) do
          nil -> nil
          hour -> latest_in(store, hour, 3600)
        end

      found ->
        found
    end
  end

  defp latest_in(store, at, seconds) do
    store
    |> samples_until(selector(store, "beam_vm_processes"), at, seconds)
    |> Enum.flat_map(& &1.values)
    |> Enum.map(&elem(&1, 0))
    |> Enum.max(fn -> nil end)
  end

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

    # Each part counted is stamped at its end, and counts what is in the
    # step before it.
    counted =
      promql_range(
        store,
        "count_over_time(#{selector(store, "beam_vm_processes")}[#{step}s])",
        oldest,
        last,
        step
      )

    first =
      with [ending | _] <-
             counted
             |> Enum.flat_map(& &1.values)
             |> Enum.filter(fn {_at, count} -> count > 0 end)
             |> Enum.map(&elem(&1, 0))
             |> Enum.sort(),
           # A step further back than the part: where its edge falls is the
           # plane's to say, and the first sample may be just before it.
           [{at, _} | _] <-
             history(store, "beam_vm_processes", nil, nil, ending - 2 * step, ending) do
        at
      else
        # Nothing counted: a store younger than a step, whose last part a
        # plane that keeps to multiples of the step, and to now, will not
        # evaluate. Its last hour is read as it is.
        _ ->
          case history(store, "beam_vm_processes", nil, nil, last - 3600, last) do
            [{at, _} | _] -> at
            [] -> last / 1
          end
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
    labels = if key, do: [{key, want}], else: []
    to = Float.ceil(to / 1)
    seconds = trunc(to - Float.floor(from / 1)) + 1

    store
    |> samples_until(selector(store, metric, labels), to, seconds)
    |> Enum.flat_map(& &1.values)
    |> Enum.filter(fn {at, _value} -> at >= from end)
    |> Enum.sort()
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
  def timeline(%__MODULE__{} = store, from, to),
    do: trend(store, "beam_vm_scheduler_util_pct", [scheduler: "all"], from, to)

  @impl true
  def trend(%__MODULE__{} = store, metric, labels, from, to) do
    span = to - from

    resolution =
      cond do
        span <= 2 * 3600 -> 0
        span <= 48 * 3600 -> 300
        true -> 3600
      end

    ranged =
      if resolution > 0 do
        # A part is stamped at its end, and is of the step before it: it is
        # said here at its beginning, as a column of a timeline is.
        store
        |> promql_range(
          "max(max_over_time(#{selector(store, metric, labels)}[#{resolution}s]))",
          from + resolution,
          Float.ceil(to / 1),
          resolution
        )
        |> Enum.flat_map(& &1.values)
        |> Enum.map(fn {at, value} -> {at - resolution, value} end)
      else
        []
      end

    case {ranged, labels} do
      {[], [{key, want} | _]} ->
        {history(store, metric, Atom.to_string(key), want, from, to),
         elem(spacing(store, to), 0) || 10.0}

      {[], []} ->
        {history(store, metric, nil, nil, from, to), elem(spacing(store, to), 0) || 10.0}

      {points, _} ->
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
        # The latest first: what is not reached is what lies further back.
        rows =
          records(store, [level: level, limit: store.most_incidents, order: "desc"], from, to)

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

  @typedoc """
  What a plane holds, and how small it holds it: `items` stored, `raw`
  bytes as the plane counts them before they are compressed, `data` bytes
  of what was compressed, and `disk` bytes of every page in use in its
  file, the indexes with it.
  """
  @type storage :: %{
          signal: :samples | :records | :spans,
          items: non_neg_integer(),
          raw: non_neg_integer(),
          data: non_neg_integer(),
          disk: non_neg_integer(),
          detail: String.t()
        }

  @doc """
  What each of the three planes holds and how small: of the whole store,
  and not of one recording. A plane that does not answer is left out.
  """
  @spec storage(t()) :: [storage()]
  def storage(%__MODULE__{} = store) do
    [
      {:metrics, "/select/metrics/stats"},
      {:logs, "/select/logsql/stats"},
      {:traces, "/select/traces/stats"}
    ]
    |> Task.async_stream(
      fn {plane, path} ->
        with {:ok, body} <- get(store, plane, path, []),
             {:ok, %{} = stats} <- JSON.decode(body) do
          storage_of(plane, stats)
        else
          _ -> nil
        end
      end,
      timeout: store.timeout + 1000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, %{} = storage} -> [storage]
      _ -> []
    end)
  end

  defp in_use(stats),
    do: max((stats["sqlite_page_bytes"] || 0) - (stats["freelist_bytes"] || 0), 0)

  # A sample is sixteen bytes before it is compressed: its time and its
  # value. Records and spans are as the planes count what they were sent.
  defp storage_of(:metrics, stats) do
    points = stats["total_points"] || 0
    chunks = stats["raw_tier_chunks"] || 0

    %{
      signal: :samples,
      items: points,
      raw: points * 16,
      data: stats["bytes_on_disk"] || 0,
      disk: in_use(stats),
      detail:
        "#{Human.count(stats["series"] || 0)} series · " <>
          "#{if chunks > 0, do: round(points / chunks), else: 0} samples to a chunk"
    }
  end

  defp storage_of(:logs, stats) do
    %{
      signal: :records,
      items: stats["total_entries"] || 0,
      raw: stats["raw_ingested_bytes_total"] || 0,
      data: stats["total_bytes"] || 0,
      disk: in_use(stats),
      detail:
        "#{stats["compressed_blocks"] || 0} blocks compressed, #{stats["raw_blocks"] || 0} not yet"
    }
  end

  defp storage_of(:traces, stats) do
    %{
      signal: :spans,
      items: stats["total_spans"] || 0,
      raw: stats["raw_ingested_bytes_total"] || 0,
      data: stats["bytes_on_disk"] || 0,
      disk: in_use(stats),
      detail:
        "#{stats["compressed_blocks"] || 0} blocks compressed, #{stats["raw_blocks"] || 0} not yet"
    }
  end

  @impl true
  def recordings(%__MODULE__{} = store, from, to) do
    # Of every node: a recording is found by when it began, whoever it was of.
    asked =
      logsql(store, from, to, [service: "recording"] ++ host(store),
        limit: @records,
        order: :desc
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
  def exits(%__MODULE__{} = store, reach, wanted),
    do: records_of(store, reach, &(&1 == "exit"), wanted)

  # What the VM remarked on: records of every kind but those of processes
  # that ended and of recordings.
  @impl true
  def remarks(%__MODULE__{} = store, reach, wanted),
    do: records_of(store, reach, &(&1 not in ["exit", "recording", nil]), wanted)

  defp records_of(store, %{until: until, span: span, limit: limit}, kind?, wanted) do
    # What is wanted is decided as the store is read, and not after: a
    # busy node ends hundreds of processes a second, and the one that is
    # looked for is seldom among the last few.
    Enum.reduce_while(0..9, {:ok, []}, fn page, {:ok, found} ->
      case logsql(store, until - span, until, host(store),
             limit: @records,
             offset: page * @records,
             order: :desc
           ) do
        {:ok, body} ->
          rows = lines(body)

          found =
            found ++
              for row <- rows,
                  kind?.(row["kind"]),
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

  # How much further back a job is looked for when its trace is not
  # found yet.
  @not_found_yet 60

  @impl true
  def jobs(%__MODULE__{traces: nil}, _reach, _width, _wanted),
    do: {:error, "Where the traces plane is was not said: --traces-url."}

  def jobs(%__MODULE__{} = store, %{until: until, span: span, limit: limit}, width, wanted) do
    case jobs_until(store, until, span, limit, width, wanted) do
      # A plane may make a trace findable some time after it was written:
      # VictoriaTraces, half a minute. What was not found yet is looked for
      # a minute further back, once.
      {:ok, jobs, missing} when missing > 0 and length(jobs) < limit ->
        case jobs_until(store, until - @not_found_yet, span, limit, width, wanted) do
          {:ok, earlier, _missing} when length(earlier) > length(jobs) -> {:ok, earlier}
          _ -> {:ok, jobs}
        end

      {:ok, jobs, _missing} ->
        {:ok, jobs}

      {:error, why} ->
        {:error, why}
    end
  end

  defp jobs_until(store, until, span, limit, width, wanted) do
    # The latest to start are the ones wanted. Every process that ended is
    # a record with the trace it was of: the last few hundred are read, the
    # traces among them that have more than one are jobs, and the spans of
    # those are read in full, a trace at a time, as Jaeger asks for one.
    pages =
      0..5
      |> Task.async_stream(
        fn page ->
          # Not filtered by kind: a plane may look through every record for
          # a field, where one in time order is read as it lies, and nearly
          # every record is of a process that ended.
          logsql(store, until - span, until, host(store),
            limit: @spans,
            offset: page * @spans,
            order: :desc
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
              row <- lines(body),
              row["kind"] == "exit",
              is_binary(row["trace_id"]) and row["trace_id"] != "",
              ours?(store, row),
              do: row

        traces =
          seen
          |> Enum.group_by(& &1["trace_id"])
          |> Enum.filter(&match?({_trace, [_, _ | _]}, &1))
          |> Enum.map(fn {trace, rows} ->
            {rows |> Enum.map(&(number(&1["started"]) || 0.0)) |> Enum.min(), trace}
          end)
          |> Enum.sort(:desc)
          |> Enum.take(min(limit, @jobs))

        found =
          traces
          |> Task.async_stream(
            fn {_start, trace} ->
              get(store, :traces, "/select/jaeger/api/traces/#{trace}", [])
            end,
            max_concurrency: 4,
            timeout: store.timeout + 1000
          )
          |> Enum.map(fn
            {:ok, {:ok, body}} ->
              case JSON.decode(body) do
                {:ok, %{"data" => [%{"spans" => [_ | _]} = trace | _]}} ->
                  trace |> jaeger_spans() |> Store.job(width)

                _ ->
                  nil
              end

            _ ->
              nil
          end)

        jobs = found |> Enum.reject(&is_nil/1) |> Enum.filter(wanted)
        {:ok, jobs, Enum.count(found, &is_nil/1)}
    end
  end

  ## What the planes say, as what the screen shows

  defp exit_of(row) do
    case moment(row["_time"]) do
      nil -> nil
      at -> Store.exit(at, row["level"] || "info", Map.drop(row, ["_msg", "_time", "level"]))
    end
  end

  # What Jaeger says of a span that is not an attribute of the process.
  @span_tags ~w(span.kind otel.status_code otel.status_description otel.scope.name otel.scope.version error)

  # The spans of a trace as Jaeger says them: a parent is what it is a
  # CHILD_OF, times are in microseconds, and the service is its process's.
  # A plane may say every tag as a string, and how a span ended only by
  # `error`: numbers and booleans are read back from what they were
  # written as.
  @doc false
  @spec jaeger_spans(map()) :: [Span.t()]
  def jaeger_spans(%{"spans" => spans} = trace) do
    processes = trace["processes"] || %{}
    Enum.flat_map(spans, &span_of(&1, processes))
  end

  defp span_of(%{"traceID" => trace, "spanID" => id, "startTime" => start} = span, processes)
       when is_number(start) do
    with {:ok, trace} <- Base.decode16(trace, case: :mixed),
         {:ok, id} <- Base.decode16(id, case: :mixed) do
      tags = Map.new(span["tags"] || [], fn tag -> {tag["key"], tag_value(tag["value"])} end)

      parent =
        Enum.find_value(span["references"] || [], fn
          %{"refType" => "CHILD_OF", "spanID" => parent} ->
            case Base.decode16(parent, case: :mixed) do
              {:ok, parent} -> parent
              :error -> nil
            end

          _ ->
            nil
        end)

      process = processes[span["processID"]] || %{}

      ok =
        case {tags["otel.status_code"], tags["error"]} do
          {"OK", _} -> true
          {"ERROR", _} -> false
          {_, true} -> false
          {_, false} -> true
          _ -> nil
        end

      [
        %Span{
          trace_id: trace,
          span_id: id,
          parent_span_id: parent,
          name: span["operationName"] || "",
          service: process["serviceName"] || "",
          ok: ok,
          ending: tags["otel.status_description"] || "",
          start_ns: trunc(start * 1000),
          duration_ns: trunc((span["duration"] || 0) * 1000),
          attributes: Map.drop(tags, @span_tags)
        }
      ]
    else
      _ -> []
    end
  end

  defp span_of(_span, _processes), do: []

  defp tag_value("true"), do: true
  defp tag_value("false"), do: false

  defp tag_value(text) when is_binary(text) do
    case Integer.parse(text) do
      {integer, ""} ->
        integer

      _ ->
        case Float.parse(text) do
          {float, ""} -> float
          _ -> text
        end
    end
  end

  defp tag_value(value), do: value

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
    {fields, options} = Keyword.split(params, [:level, :service, :kind])

    options =
      Enum.map(options, fn
        {:order, order} -> {:order, String.to_existing_atom(order)}
        other -> other
      end)

    case logsql(store, from, to, fields ++ host(store), options) do
      {:ok, body} -> lines(body)
      {:error, _} -> []
    end
  end

  ## LogsQL

  # Records between two times, whose fields are exactly those given, as
  # LogsQL: the time and the fields as filters, then the order, how many
  # to pass over, and how many to give. Asked by POST, which every plane
  # that speaks LogsQL takes, with the time in the query.
  defp logsql(store, from, to, fields, options) do
    time =
      "_time:[#{iso(Float.floor(from / 1))}, #{iso(Float.ceil(to / 1))}]"

    filters = for {field, value} <- fields, do: ~s[#{field}:="#{escape(to_string(value))}"]

    pipes =
      case options[:order] do
        :desc -> ["sort by (_time desc)"]
        :asc -> ["sort by (_time)"]
        nil -> []
      end ++
        if(options[:offset] && options[:offset] > 0, do: ["offset #{options[:offset]}"], else: []) ++
        if(options[:limit], do: ["limit #{options[:limit]}"], else: [])

    query = Enum.join([time | filters], " ") <> Enum.map_join(pipes, &(" | " <> &1))
    post(store, :logs, "/select/logsql/query", query: query)
  end

  defp iso(seconds), do: seconds |> trunc() |> DateTime.from_unix!() |> DateTime.to_iso8601()

  # The labels that say whose series are wanted.
  defp who(%__MODULE__{node: node, host: host}),
    do: for({key, value} <- [node: node, host: host], is_binary(value), do: {key, value})

  defp host(%__MODULE__{host: host}), do: if(is_binary(host), do: [host: host], else: [])

  # One thing to a line.
  defp lines(body) do
    for line <- String.split(body, "\n", trim: true),
        {:ok, %{} = row} <- [JSON.decode(line)],
        do: numbers(row)
  end

  # The fields of a record that are numbers, as numbers. A plane may give
  # every field back as text, as VictoriaLogs does; what is an id, or a
  # name, is left as it is, though it be all digits.
  @numbers ~w(elapsed_seconds seen_seconds reductions peak_memory_bytes started stop_at
              stop_after max_recording value)

  defp numbers(row) do
    Enum.reduce(@numbers, row, fn field, row ->
      case row do
        %{^field => text} when is_binary(text) ->
          case number(text) do
            nil -> row
            value -> %{row | field => value}
          end

        _ ->
          row
      end
    end)
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

  ## PromQL

  # A series selector: the metric, the node's labels, and any more.
  defp selector(store, metric, labels \\ []) do
    matchers =
      for {key, value} <- labels ++ who(store),
          do: ~s[#{key}="#{escape(to_string(value))}"]

    metric <> "{" <> Enum.join(matchers, ",") <> "}"
  end

  # The raw samples of a selector in the `seconds` up to `at`, with their
  # own times: a range selector, asked at a moment.
  defp samples_until(store, selector, at, seconds) do
    store
    |> get(:metrics, "/api/v1/query",
      query: "#{selector}[#{max(trunc(seconds), 1)}s]",
      time: trunc(Float.ceil(at / 1))
    )
    |> series_of()
  end

  # A plane may put the times it evaluates at on multiples of the step,
  # and stop at the last of them before `end`: one step more is asked for,
  # so that the last part is evaluated wherever the multiples fall, and
  # what is past it is left out.
  defp promql_range(store, query, from, to, step) do
    to = Float.ceil(to / 1)

    store
    |> get(:metrics, "/api/v1/query_range",
      query: query,
      start: trunc(Float.floor(from / 1)),
      end: trunc(to + step),
      step: trunc(step)
    )
    |> series_of()
    |> Enum.map(fn series ->
      %{series | values: Enum.filter(series.values, fn {at, _} -> at - step < to end)}
    end)
  end

  # The series of an answer, a matrix or a vector, as their labels and
  # `{seconds, value}` in time order. Nothing, if it was not an answer.
  defp series_of({:ok, body}) do
    case JSON.decode(body) do
      {:ok, %{"status" => "success", "data" => %{"result" => result}}} when is_list(result) ->
        for %{"metric" => labels} = series <- result do
          points = series["values"] || List.wrap(series["value"])

          values =
            for [at, value] <- points,
                is_number(at),
                value = number(value),
                is_number(value),
                do: {at / 1, value}

          %{labels: labels, values: values}
        end

      _ ->
        []
    end
  end

  defp series_of({:error, _}), do: []

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

  defp post(%__MODULE__{} = store, plane, path, form, again \\ true) do
    case Map.fetch!(store, plane) do
      nil ->
        {:error, "Where the #{plane} plane is was not said: --#{plane}-url."}

      base ->
        headers =
          [{"content-type", "application/x-www-form-urlencoded"}] ++
            case store.tokens[plane] do
              token when is_binary(token) and token != "" ->
                [{"authorization", "Bearer " <> token}]

              _ ->
                []
            end

        case Http.post(base <> path, URI.encode_query(form), headers, store.timeout, keep: @keep) do
          {:ok, status, body} when status in 200..299 ->
            {:ok, body}

          {:ok, status, _body} when again and status in [503, 429] ->
            Process.sleep(@again_ms)
            post(store, plane, path, form, false)

          {:ok, status, body} ->
            {:error, "#{base} answered #{status}: #{said(body)}"}

          {:error, reason} ->
            {:error, "#{base}: #{Http.format_error(reason)}"}
        end
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
