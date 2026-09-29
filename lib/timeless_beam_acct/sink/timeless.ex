defmodule TimelessBeamAcct.Sink.Timeless do
  @moduledoc """
  The Timeless stores running in this node.

  An application that embeds `timeless_metrics`, `timeless_logs`, and
  `timeless_traces` (through `timeless_phoenix`, or by itself) has the
  three stores in the node the collector runs in. This sink hands them what
  a tick produced by calling them. Nothing is encoded as text, nothing
  crosses a socket, and nothing is kept a second time.

  The libraries are not dependencies of this package. They are looked for
  when the sink starts, and a signal whose library is not in the node is
  refused then, by name, unless it has been turned off.

  ## Options

  | option | default | |
  |---|---|---|
  | `:metrics` | `:tp_default_timeless` | the name of the `TimelessMetrics` store, or `false` to store no samples |
  | `:logs` | `true` | store records in `TimelessLogs` |
  | `:traces` | `true` | store spans in `TimelessTraces` |
  | `:timeout` | `30` | seconds a store is given to take what it is handed |
  | `:metrics_module` | `TimelessMetrics` | the module called for samples |
  | `:logs_module` | `TimelessLogs` | the module called for records |
  | `:traces_module` | `TimelessTraces` | the module called for spans |

  A metrics store has the name it was started with, and there may be
  several in a node. `timeless_phoenix` names the one it starts
  `:tp_<name>_timeless`, and its `<name>` is `:default` unless it is given
  another, so `:tp_default_timeless` is the store of an application that
  added `{TimelessPhoenix, data_dir: ...}` to its supervision tree and
  nothing else. A store started as `{TimelessMetrics, name: :metrics, ...}`
  is given as `metrics: :metrics`. The logs and traces stores are one to a
  node and have no name.

  ## What is checked when the sink starts

  For each signal that is on: that the module is loaded, that it exports
  the function that will be called, and that the store is running. A
  metrics store is running if its supervisor, `:<name>_sup`, is. The logs
  and traces stores are running if the process of either of their engines
  is. What cannot be reached is an error that says what is missing and what
  to do about it. A signal that is off is not checked and not written.

  ## What is handed to the stores

  The planes are given the same tick by `TimelessBeamAcct.Sink.Http`. What
  is stored here is what the HTTP routes of these libraries would have made
  of that, but for what is said under "What differs from the routes".

  `host` and `node` are the sink's to give. A label, a field, or a
  resource of the same name is replaced.

  **Samples** go to `write_batch/2` as `{name, labels, value, timestamp}`.
  The labels are a map of strings: the sample's own, and `host` and `node`.
  The value is a float, which is what the text route parses every value
  to. The timestamp is `batch.ts`, in seconds: the text route is sent
  milliseconds and divides them by a thousand.

  **Records** go to `ingest/1` as
  `%{timestamp: ts_us, level: level, message: message, metadata: metadata}`.
  The metadata is the record's fields and `host` and `node`, with string
  keys. Values keep their types: the stores keep a number as a number and
  a boolean as a boolean, and give them back so, as they do for a JSON
  line. The timestamp is microseconds, which the store recognises by its
  size. `service`, `host`, `node`, `path`, and `status` are among the keys
  the libSQL engine indexes; the older engine indexes those but `node`,
  and only where the value is a string.

  **Spans** are maps with the keys the OTLP/JSON route builds: `trace_id`,
  `span_id`, and `parent_span_id` in lowercase hexadecimal, `kind:
  :internal`, `start_time` and `end_time` in nanoseconds, `duration_ns`,
  `status` as `:ok`, `:error`, or `:unset`, `status_message`, `attributes`
  with string keys and typed values, `events: []`, `resource`, and
  `instrumentation_scope`. The resource is `service.name`, `host.name`, and
  `service.instance.id`, which is the node.

  ## What differs from the routes

  The level of a record is handed over as it is. `TimelessLogs`' own
  `/insert/jsonline` route knows `debug`, `info`, `warning`, `warn`, and
  `error`, and reads every other level as `info`, so a `notice` sent
  through it is stored as `info`. Here the store is handed `:notice`. The
  libSQL engine keeps it, as the logs plane does, and as the local store
  of `timeless-acct` does. The older engine keeps it until it compacts the
  block the record is in; its compacted blocks have four levels, and a
  `notice` is read from them as `info`, which is then the same as the
  route.

  `TimelessTraces` has no public function that takes spans. Its exporter
  and its HTTP route both call `TimelessTraces.StorageEngine.ingest/1`, and
  so does this sink. `TimelessTraces.Buffer.ingest/1` belongs to the older
  engine: under the libSQL engine its processes are not started, and what
  is cast to them is dropped without a word. A `:traces_module` that
  exports `ingest/1` is called itself. One that does not is expected to
  have a `StorageEngine` beneath it that does.

  The routes answer before anything is stored: the text route puts the
  body in a queue. Here the call returns when the store has taken the
  batch, and an error is the store's own.

  ## A store that fails

  Each signal is stored by itself. One that fails does not keep the others
  from being stored, and the error returned is the first one met, naming
  its signal.

  Every call to a store is made from a process of its own, which the
  writer monitors and is not linked to. An exception, an exit, a link that
  breaks inside the library, or a store that never answers ends that
  process and not the writer. The caller is put in `$callers`, as `Task`
  does, for whatever in the library looks there.

  A store is asked for before each call, as it is when the sink starts,
  and one that is not running is an error without being called. The
  older engines of the logs and traces libraries are written to by casts,
  and a cast to a process that is not there answers `:ok`: called, they
  would take a tick and lose it without a word.

  An error is one line. An exit from a call carries the call, and with it
  the whole batch; the error says which call it was and leaves the batch
  out.

  ## There is no backlog

  The HTTP sink keeps what it could not send, because a plane is another
  program: it can be restarted, or be unreachable for a minute, while the
  node that collects goes on. These stores are in the node. If one is gone
  its supervisor is restarting it or has given up, and either way there is
  nothing to wait for that a restart of the application would not also
  lose. Keeping ticks in memory for a store that may not come back would
  take memory from the node that is already in trouble.

  What could not be stored is counted instead. `describe/1` and every
  error say how many ticks were lost: a tick counts once, whatever part of
  it was not stored.

  ## A module in between

  The three `_module` options name what is called. They are there so that
  the sink can be tested with none of the libraries present, and so that a
  release that wraps its stores can put its own module in between. Such a
  module exports `write_batch/2` for samples, or `ingest/1` for records or
  spans. If it exports a flush (`flush/1` for samples, taking the store's
  name; `flush/0` for the others) it is flushed. If it exports `running?/1`
  (samples, taking the store's name) or `running?/0`, that is asked when
  the sink starts and before each call; otherwise it is taken to be
  running.
  """

  @behaviour TimelessBeamAcct.Sink

  alias TimelessBeamAcct.{Batch, Clock, Encode, Event, Span, Tick}

  @default_store :tp_default_timeless
  @signals [:metrics, :logs, :traces]
  @known [:metrics, :logs, :traces, :metrics_module, :logs_module, :traces_module, :timeout]

  # The libraries, by signal. The modules are named here and never called
  # by name: they may not be there.
  @libraries %{
    metrics: %{module: TimelessMetrics, app: :timeless_metrics, requirement: "~> 6.6"},
    logs: %{module: TimelessLogs, app: :timeless_logs, requirement: "~> 1.11"},
    traces: %{module: TimelessTraces, app: :timeless_traces, requirement: "~> 1.11"}
  }

  # The process of either engine: libSQL, or the one before it.
  @engines %{
    logs: [TimelessLogs.LibsqlEngine, TimelessLogs.Index],
    traces: [TimelessTraces.LibsqlEngine, TimelessTraces.Index]
  }

  @what %{metrics: "sample", logs: "record", traces: "span"}

  # Characters of a reason.
  @longest 300

  @type signal :: :metrics | :logs | :traces

  @type t :: %__MODULE__{
          metrics: atom() | false,
          logs: boolean(),
          traces: boolean(),
          metrics_module: module(),
          logs_module: module(),
          traces_module: module(),
          traces_ingest: module() | nil,
          flushed: [signal()],
          timeout: pos_integer(),
          lost_ticks: non_neg_integer(),
          lost: %{signal() => non_neg_integer()}
        }

  defstruct metrics: @default_store,
            logs: true,
            traces: true,
            metrics_module: TimelessMetrics,
            logs_module: TimelessLogs,
            traces_module: TimelessTraces,
            # The module whose `ingest/1` takes spans.
            traces_ingest: nil,
            # The signals whose store has a flush.
            flushed: [],
            # Milliseconds.
            timeout: 30_000,
            lost_ticks: 0,
            # Samples, records, and spans that were not stored.
            lost: %{metrics: 0, logs: 0, traces: 0}

  @doc "The metrics store written to when none is named: `timeless_phoenix`'s."
  @spec default_store() :: atom()
  def default_store, do: @default_store

  @doc """
  Make the sink, and check that every store asked for can be reached.

  The error is a sentence: what is missing, and what to do about it.
  """
  @impl true
  @spec init(keyword()) :: {:ok, t()} | {:error, String.t()}
  def init(opts) when is_list(opts) do
    with :ok <- known(opts),
         {:ok, state} <- configured(opts),
         :ok <- something_to_write(state) do
      reach(state)
    end
  end

  @doc """
  Hand each store its part of the tick.

  A part with nothing in it is not handed over. If a store fails, the
  others are still written to, the tick is counted as lost, and the first
  error is returned.
  """
  @impl true
  @spec write(t(), String.t(), String.t(), Tick.t()) :: {:ok, t()} | {:error, String.t(), t()}
  def write(%__MODULE__{} = state, host, node, %Tick{} = tick)
      when is_binary(host) and is_binary(node) do
    %Tick{metrics: batch, events: events, spans: spans} = tick

    parts = [
      {:metrics, batch.samples,
       fn ->
         apply(state.metrics_module, :write_batch, [state.metrics, samples(host, node, batch)])
       end},
      {:logs, events, fn -> apply(state.logs_module, :ingest, [entries(host, node, events)]) end},
      {:traces, spans, fn -> apply(state.traces_ingest, :ingest, [spans(host, node, spans)]) end}
    ]

    failures =
      for {signal, [_ | _] = items, call} <- parts,
          on?(state, signal),
          {:error, why} <- [handed(state, signal, call)] do
        {signal, length(items), why}
      end

    case failures do
      [] ->
        {:ok, state}

      [{signal, count, why} | _] ->
        state = lose(state, failures)

        {:error,
         "#{signal}: #{counted(count, @what[signal])} not stored#{place(state, signal)}: " <>
           "#{why} (#{counted(state.lost_ticks, "tick")} lost since the sink started)", state}
    end
  end

  @doc """
  Flush every store that has a flush.

  A store that cannot be flushed does not keep the others from being
  flushed. The first error is returned.
  """
  @impl true
  @spec flush(t()) :: {:ok, t()} | {:error, String.t(), t()}
  def flush(%__MODULE__{} = state) do
    failures =
      for signal <- state.flushed,
          {:error, why} <- [handed(state, signal, flush_of(state, signal))] do
        {signal, why}
      end

    case failures do
      [] ->
        {:ok, state}

      [{signal, why} | _] ->
        {:error, "#{signal}: not flushed#{place(state, signal)}: #{why}", state}
    end
  end

  @doc """
  Flush, and nothing else. The stores belong to the application that
  started them, and are not this sink's to stop.
  """
  @impl true
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = state) do
    _ = flush(state)
    :ok
  end

  @doc "Which stores are written to, and how many ticks were lost, if any."
  @impl true
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = state) do
    stores =
      for signal <- @signals, on?(state, signal) do
        "#{signal}#{place(state, signal)}#{through(state, signal)}"
      end

    "timeless: " <> Enum.join(stores, ", ") <> lost(state)
  end

  @doc """
  Samples as `TimelessMetrics.write_batch/2` takes them.

  `host` and `node` are added to the labels of each, and are the sink's to
  give: a label of a sample's own by either name is replaced.
  """
  @spec samples(String.t(), String.t(), Batch.t()) ::
          [{String.t(), %{String.t() => String.t()}, float(), integer()}]
  def samples(host, node, %Batch{ts: ts} = batch) do
    for {name, labels, value} <- Batch.samples(batch) do
      {name, labels(host, node, labels), value * 1.0, ts}
    end
  end

  @doc """
  Records as `TimelessLogs.ingest/1` takes them: the fields of each, and
  `host` and `node`, are its metadata.
  """
  @spec entries(String.t(), String.t(), [Event.t()]) :: [map()]
  def entries(host, node, events) when is_list(events) do
    for %Event{} = event <- events do
      %{
        timestamp: event.ts_us,
        level: event.level,
        message: event.message,
        # As the planes are sent it, so that a record is the same record
        # whichever way it arrived.
        metadata: Encode.event_metadata(host, node, event)
      }
    end
  end

  @doc "Spans as `TimelessTraces` takes them: what its OTLP/JSON route makes of a request."
  @spec spans(String.t(), String.t(), [Span.t()]) :: [map()]
  def spans(host, node, spans) when is_list(spans) do
    scope = scope()

    for %Span{} = span <- spans do
      %{
        trace_id: Span.hex(span.trace_id),
        span_id: Span.hex(span.span_id),
        parent_span_id: span.parent_span_id && Span.hex(span.parent_span_id),
        name: span.name,
        kind: :internal,
        start_time: span.start_ns,
        end_time: span.start_ns + span.duration_ns,
        duration_ns: span.duration_ns,
        status: Span.status(span),
        status_message: span.ending,
        attributes: Map.new(span.attributes, fn {key, value} -> {to_string(key), value} end),
        events: [],
        resource: resource(host, node, span),
        instrumentation_scope: scope
      }
    end
  end

  @doc "What a span's resource is: the application, in the node, on the host."
  @spec resource(String.t(), String.t(), Span.t()) :: %{String.t() => String.t()}
  def resource(host, node, %Span{} = span), do: Encode.resource(host, node, span)

  @doc "What every span of this collector's is said to come from."
  @spec scope() :: %{name: String.t(), version: String.t() | nil}
  def scope do
    %{"name" => name, "version" => version} = Encode.scope()
    %{name: name, version: version}
  end

  defp labels(host, node, labels) do
    labels
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
    |> Map.merge(%{"host" => host, "node" => node})
  end

  ## Options

  defp known(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, "the options of the :timeless sink are a keyword list, not #{inspect(opts)}"}

      unknown = Enum.find(Keyword.keys(opts), &(&1 not in @known)) ->
        {:error,
         "unknown option #{inspect(unknown)} of the :timeless sink: its options are " <>
           Enum.map_join(@known, ", ", &inspect/1)}

      true ->
        :ok
    end
  end

  defp configured(opts) do
    Enum.reduce_while(opts, {:ok, %__MODULE__{}}, fn {key, value}, {:ok, state} ->
      case check(key, value) do
        {:ok, value} -> {:cont, {:ok, Map.put(state, key, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check(:metrics, true), do: {:ok, @default_store}
  defp check(:metrics, false), do: {:ok, false}
  defp check(:metrics, store) when is_atom(store) and not is_nil(store), do: {:ok, store}

  defp check(:metrics, value),
    do: wrong(:metrics, value, "the name of a TimelessMetrics store (an atom), or false")

  defp check(key, value) when key in [:logs, :traces] do
    if is_boolean(value), do: {:ok, value}, else: wrong(key, value, "true or false")
  end

  defp check(:timeout, value) do
    case Clock.parse_span(value) do
      {:ok, seconds} when seconds > 0 -> {:ok, max(round(seconds * 1000), 1)}
      {:ok, _zero} -> {:error, ":timeout must be more than no time"}
      {:error, why} -> {:error, ":timeout: #{why}"}
    end
  rescue
    FunctionClauseError -> wrong(:timeout, value, "a length of time")
  end

  defp check(key, value) when key in [:metrics_module, :logs_module, :traces_module] do
    if is_atom(value) and value not in [nil, true, false],
      do: {:ok, value},
      else: wrong(key, value, "a module")
  end

  defp wrong(key, value, expected),
    do: {:error, "#{inspect(key)} is #{inspect(value)}: expected #{expected}"}

  defp something_to_write(state) do
    if Enum.any?(@signals, &on?(state, &1)),
      do: :ok,
      else: {:error, "metrics, logs, and traces are all off: the :timeless sink has no store"}
  end

  ## Reaching the stores

  defp reach(state) do
    @signals
    |> Enum.filter(&on?(state, &1))
    |> Enum.reduce_while({:ok, state}, fn signal, {:ok, state} ->
      case reach(signal, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp reach(:metrics, state) do
    module = state.metrics_module

    with :ok <- loaded(:metrics, module),
         :ok <- exports(:metrics, module, :write_batch, 2),
         :ok <- running(:metrics, module, state) do
      {:ok, flushed(state, :metrics, module, 1)}
    end
  end

  defp reach(:logs, state) do
    module = state.logs_module

    with :ok <- loaded(:logs, module),
         :ok <- exports(:logs, module, :ingest, 1),
         :ok <- running(:logs, module, state) do
      {:ok, flushed(state, :logs, module, 0)}
    end
  end

  defp reach(:traces, state) do
    module = state.traces_module

    with :ok <- loaded(:traces, module),
         {:ok, ingest} <- takes_spans(module),
         :ok <- running(:traces, module, state) do
      {:ok, flushed(%{state | traces_ingest: ingest}, :traces, module, 0)}
    end
  end

  defp loaded(signal, module) do
    %{module: library, app: app, requirement: requirement} = @libraries[signal]

    cond do
      Code.ensure_loaded?(module) ->
        :ok

      module == library ->
        {:error,
         "#{signal}: #{inspect(module)} is not loaded: #{inspect(app)} is not in this node. " <>
           "Add {#{inspect(app)}, #{inspect(requirement)}} to the dependencies of the " <>
           "application the collector runs in, or turn the signal off with #{signal}: false"}

      true ->
        {:error,
         "#{signal}: #{inspect(module)}, given as :#{signal}_module, is not loaded. " <>
           "Name a module that is in this node, or turn the signal off with #{signal}: false"}
    end
  end

  defp exports(signal, module, function, arity) do
    if function_exported?(module, function, arity) do
      :ok
    else
      {:error,
       "#{signal}: #{inspect(module)} does not export #{function}/#{arity}, which is what " <>
         "#{@what[signal]}s are handed to. #{version(signal, module)}"}
    end
  end

  # `TimelessTraces` takes spans a level down. A module put in between
  # takes them itself.
  defp takes_spans(module) do
    beneath = Module.concat(module, StorageEngine)

    cond do
      function_exported?(module, :ingest, 1) ->
        {:ok, module}

      Code.ensure_loaded?(beneath) and function_exported?(beneath, :ingest, 1) ->
        {:ok, beneath}

      true ->
        {:error,
         "traces: neither #{inspect(module)} nor #{inspect(beneath)} exports ingest/1, which " <>
           "is what spans are handed to. #{version(:traces, module)}"}
    end
  end

  defp version(signal, module) do
    %{module: library, app: app, requirement: requirement} = @libraries[signal]

    if module == library do
      found =
        case Application.spec(app, :vsn) do
          nil -> "the one in this node"
          vsn -> to_string(vsn)
        end

      "This sink is written for #{inspect(app)} #{requirement}, and #{found} is not that: " <>
        "change the version, or turn the signal off with #{signal}: false"
    else
      "Name a module that does, or turn the signal off with #{signal}: false"
    end
  end

  defp running(signal, module, state) do
    if running?(signal, module, state), do: :ok, else: {:error, stopped(signal, module, state)}
  end

  defp running?(:metrics, TimelessMetrics, %{metrics: store}),
    do: alive?(:"#{store}_sup")

  defp running?(:logs, TimelessLogs, _state), do: Enum.any?(@engines.logs, &alive?/1)
  defp running?(:traces, TimelessTraces, _state), do: Enum.any?(@engines.traces, &alive?/1)

  defp running?(:metrics, module, %{metrics: store}), do: asked(module, :running?, [store])
  defp running?(_signal, module, _state), do: asked(module, :running?, [])

  defp alive?(name) do
    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  # A module put in between says whether its store is running, if it can.
  defp asked(module, function, arguments) do
    if function_exported?(module, function, length(arguments)) do
      apply(module, function, arguments) == true
    else
      true
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp stopped(:metrics, module, %{metrics: store}) do
    "metrics: no store named #{inspect(store)} is running in this node. Start " <>
      "{#{inspect(module)}, name: #{inspect(store)}, data_dir: ...} before the collector, " <>
      "name the store that is running with metrics: its_name, or turn the signal off with " <>
      "metrics: false"
  end

  defp stopped(signal, module, _state) do
    %{app: app} = @libraries[signal]

    "#{signal}: the store of #{inspect(module)} is not running in this node. Start the " <>
      "#{inspect(app)} application before the collector, and see that it is not configured " <>
      "with owner: :external, which starts it without a store; or turn the signal off with " <>
      "#{signal}: false"
  end

  defp flushed(state, signal, module, arity) do
    if function_exported?(module, :flush, arity),
      do: %{state | flushed: state.flushed ++ [signal]},
      else: state
  end

  defp flush_of(%{metrics_module: module, metrics: store}, :metrics),
    do: fn -> apply(module, :flush, [store]) end

  defp flush_of(%{logs_module: module}, :logs), do: fn -> apply(module, :flush, []) end
  defp flush_of(%{traces_module: module}, :traces), do: fn -> apply(module, :flush, []) end

  ## Calling a store

  # A store is asked for before it is called. The older engines of the logs
  # and traces libraries are written to by casts, and a cast to a process
  # that is not there is an `:ok`.
  defp handed(state, signal, call) do
    module = Map.fetch!(state, :"#{signal}_module")

    isolated(
      fn ->
        if running?(signal, module, state),
          do: call.(),
          else: {:error, "the store is not running"}
      end,
      state.timeout
    )
  end

  # The call is made from a process of its own: whatever happens to it
  # there, the writer hears of it and goes on.
  defp isolated(call, timeout) do
    parent = self()
    tag = make_ref()
    callers = [parent | Process.get(:"$callers", [])]

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        send(parent, {tag, attempt(call)})
      end)

    receive do
      {^tag, answer} ->
        Process.demonitor(monitor, [:flush])
        answer

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, "exited: #{exit_text(reason)}"}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^tag, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, "no answer in #{timeout / 1000} s"}
    end
  end

  defp attempt(call) do
    case call.() do
      :ok -> :ok
      # `TimelessMetrics` says so when there was nothing to do.
      :noop -> :ok
      {:ok, _} -> :ok
      {:error, reason} when is_binary(reason) -> {:error, brief(reason)}
      {:error, reason} -> {:error, shown(reason)}
      other -> {:error, "answered #{shown(other)}"}
    end
  rescue
    exception ->
      {:error, "raised #{inspect(exception.__struct__)}: #{brief(Exception.message(exception))}"}
  catch
    :exit, reason -> {:error, "exited: #{exit_text(reason)}"}
    :throw, value -> {:error, "threw #{shown(value)}"}
  end

  # An exit from a call carries the call, and the call carries the batch.
  # The reason says where, and leaves out what.
  defp exit_text({reason, {module, function, [server | _]}})
       when is_atom(module) and is_atom(function) do
    "#{exit_text(reason)}, in #{inspect(module)}.#{function} to #{shown(server)}"
  end

  defp exit_text(reason), do: reason |> Exception.format_exit() |> brief()

  defp shown(term), do: term |> inspect(limit: 20, printable_limit: 200) |> brief()

  # One line, and not a long one: it is written to a log.
  defp brief(text) do
    line = text |> String.split() |> Enum.join(" ")

    if String.length(line) > @longest,
      do: String.slice(line, 0, @longest) <> "...",
      else: line
  end

  ## Counting what was lost

  defp lose(state, failures) do
    lost =
      Enum.reduce(failures, state.lost, fn {signal, count, _why}, lost ->
        Map.update!(lost, signal, &(&1 + count))
      end)

    %{state | lost: lost, lost_ticks: state.lost_ticks + 1}
  end

  defp lost(%{lost_ticks: 0}), do: ""

  defp lost(%{lost_ticks: ticks, lost: lost}) do
    parts =
      for signal <- @signals, lost[signal] > 0 do
        counted(lost[signal], @what[signal])
      end

    " (#{counted(ticks, "tick")} lost: #{Enum.join(parts, ", ")})"
  end

  defp counted(1, what), do: "1 #{what}"
  defp counted(count, what), do: "#{count} #{what}s"

  ## Naming the stores

  defp on?(%{metrics: store}, :metrics), do: store != false
  defp on?(%{logs: on}, :logs), do: on
  defp on?(%{traces: on}, :traces), do: on

  defp place(%{metrics: store}, :metrics), do: " in #{inspect(store)}"
  defp place(_state, _signal), do: ""

  # Said only of a module that is not the library's own.
  defp through(state, signal) do
    module = Map.fetch!(state, :"#{signal}_module")

    if module == @libraries[signal].module,
      do: "",
      else: " through #{inspect(module)}"
  end
end
