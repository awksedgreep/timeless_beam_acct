defmodule TimelessBeamAcct.Options do
  @moduledoc """
  What a collector is told, checked once, when it starts.

  A length of time is a number of seconds or is written as `"90s"`, `"15m"`,
  `"2h"`, `"1d"`. A size is a number of bytes.

  ## What is collected

  | option | default | |
  |---|---|---|
  | `:host` | the hostname | the name this host is recorded under |
  | `:node` | the node's name | the name this node is recorded under |
  | `:interval` | `10` | seconds between readings of the VM |
  | `:process_interval` | `10` | seconds between sweeps of the processes |
  | `:sweep_budget` | `0.1` | the share of one scheduler a sweep may take: a sweep that takes longer is made less often |
  | `:vm` | `true` | report the VM |
  | `:processes` | `true` | sweep the processes |
  | `:apps` | `true` | report applications |
  | `:ets` | `true` | report tables |
  | `:dist` | `true` | report connections to other nodes |
  | `:per_scheduler` | `true` | report each scheduler, and not only all of them together |
  | `:msacc` | `false` | turn microstate accounting on, and report what the VM's threads spend their time on |

  ## Which processes get series of their own

  | option | default | |
  |---|---|---|
  | `:min_age` | `30` | seconds a process must have lived |
  | `:max_processes` | `200` | how many may have series at once |
  | `:notable_memory` | `16 MiB` | memory that makes a process without a name worth a series |
  | `:notable_queue` | `1000` | or this many messages waiting |
  | `:notable_work` | `1.0` | or this share of the VM's reductions, in percent |
  | `:max_groups` | `200` | groups reported by name; the rest are reported together as `other` |
  | `:max_tables` | `100` | tables reported by name; the rest are reported together as `other` |

  ## Exits, traces, and remarks

  | option | default | |
  |---|---|---|
  | `:exits` | `true` | ask the VM for word of each process that starts and ends |
  | `:descriptions` | `true` | and of what each task is given to do, and what each process labels itself |
  | `:records` | `:all` | which exits get a record: `:all`, `:abnormal`, or `:none` |
  | `:max_records` | `5000` | records kept from one tick of processes that ended as they were meant to, and as many again of those that did not |
  | `:exit_levels` | see below | the level of a record, by how the process ended |
  | `:traces` | `true` | keep a span for each process that ends |
  | `:trace_max_age` | `"1h"` | how long after a job starts a process may start and be part of its trace |
  | `:trace_roots` | `[]` | modules whose processes start jobs and are not part of them, beside supervisors |
  | `:anomalies` | `true` | record what the VM remarks on (OTP 28) |
  | `:long_gc` | `100` | milliseconds a garbage collection may take unremarked, or `false` |
  | `:long_schedule` | `100` | milliseconds a process may run uninterrupted, or `false` |
  | `:large_heap` | `256 MiB` | the size a heap may reach, or `false` |
  | `:long_message_queue` | `{5_000, 10_000}` | remarked on at the second, and again as over when back at the first, or `false` |
  | `:busy_port` | `true` | a process suspended on a busy port |
  | `:busy_dist_port` | `true` | a process suspended on a busy connection to a node |
  | `:max_anomalies` | `50` | remarks recorded from one tick |
  | `:trace_max_queue` | `100_000` | messages the tracer may have waiting before it stops listening |
  | `:trace_resume_after` | `5` | seconds it then waits before listening again |
  | `:history` | `2000` | records, and spans, kept in memory for `TimelessBeamAcct.exits/1` and `trees/1`: about a kilobyte each |

  What is asked for here is asked of the VM, and a VM gives what it has.
  Without trace sessions (OTP 27) no exit is heard of, no span is kept,
  and nothing is described. Without a system monitor for a trace session
  (OTP 28) nothing is remarked on. A collector told to do what its VM
  cannot starts, and does the rest: `TimelessBeamAcct.check/1` says what
  the VM lacks.

  `:exit_levels` defaults to
  `%{normal: :info, abnormal: :notice, killed: :warning, crashed: :error}`.
  A canvas host element turns red on an error and amber on a warning, so
  these decide the colour of the host.

  ## Where it goes

  | option | default | |
  |---|---|---|
  | `:sink` | `:http` | `:http`, `:timeless`, `:stdout`, `:forward`, or a module; or any of those with its options, as `{:http, token: "..."}` |
  | `:flush_interval` | `60` | seconds between flushes of the sink |
  | `:metrics_url` | `http://127.0.0.1:8428` | the metrics plane |
  | `:logs_url` | `http://127.0.0.1:9428` | the logs plane |
  | `:traces_url` | `http://127.0.0.1:10428` | the traces plane |
  | `:token` | | a bearer token, if the planes require one |
  | `:metrics_token`, `:logs_token`, `:traces_token` | `:token` | the token of one plane: a plane takes a token issued for its signal |
  | `:timeout` | `5` | seconds a plane is given to answer |
  | `:backlog` | `360` | ticks kept while a plane is unreachable |

  The last nine are options of the `:http` sink, and may be given beside
  `:sink` or with it.
  """

  alias TimelessBeamAcct.{Clock, Sink}

  @mib 1024 * 1024

  @type t :: %__MODULE__{}

  defstruct name: TimelessBeamAcct,
            host: nil,
            node: nil,
            sink: {Sink.Http, []},
            flush_interval: 60.0,
            interval: 10.0,
            process_interval: 10.0,
            sweep_budget: 0.1,
            vm: true,
            processes: true,
            apps: true,
            ets: true,
            dist: true,
            per_scheduler: true,
            msacc: false,
            min_age: 30.0,
            max_processes: 200,
            notable_memory: 16 * @mib,
            notable_queue: 1000,
            notable_work: 1.0,
            max_groups: 200,
            max_tables: 100,
            exits: true,
            descriptions: true,
            records: :all,
            max_records: 5000,
            exit_levels: %{normal: :info, abnormal: :notice, killed: :warning, crashed: :error},
            traces: true,
            trace_max_age: 3600.0,
            trace_roots: [],
            anomalies: true,
            long_gc: 100,
            long_schedule: 100,
            large_heap: 256 * @mib,
            long_message_queue: {5_000, 10_000},
            busy_port: true,
            busy_dist_port: true,
            max_anomalies: 50,
            trace_max_queue: 100_000,
            trace_resume_after: 5.0,
            history: 2_000

  @http_keys [:metrics_url, :logs_url, :traces_url, :token, :timeout, :backlog] ++
               [:metrics_token, :logs_token, :traces_token]
  @spans [
    :flush_interval,
    :interval,
    :process_interval,
    :min_age,
    :trace_max_age,
    :trace_resume_after
  ]
  @flags [
           :vm,
           :processes,
           :apps,
           :ets,
           :dist,
           :per_scheduler,
           :msacc,
           :exits,
           :traces,
           :anomalies
         ] ++
           [:busy_port, :busy_dist_port, :descriptions]
  @counts [:max_processes, :max_groups, :max_tables, :max_records, :max_anomalies, :history] ++
            [:trace_max_queue, :notable_queue, :notable_memory]
  @levels [:info, :notice, :warning, :error]

  @doc """
  The options, checked. Raises `ArgumentError` naming the first that is
  wrong, because a collector that starts with a misspelt option collects
  something other than what was asked for.
  """
  @spec new!(keyword() | t()) :: t()
  def new!(%__MODULE__{} = options), do: options

  def new!(given) when is_list(given) do
    {http, given} = Keyword.split(given, @http_keys)
    known = Map.keys(%__MODULE__{}) -- [:__struct__]

    case Enum.uniq(Keyword.keys(given)) -- known do
      [] -> :ok
      [unknown | _] -> raise ArgumentError, "unknown option #{inspect(unknown)}"
    end

    given
    |> Enum.reduce(%__MODULE__{}, fn {key, value}, options ->
      Map.put(options, key, check!(key, value))
    end)
    |> with_sink(http)
    |> with_names()
    |> consistent!()
  end

  defp check!(key, value) when key in @spans do
    case Clock.parse_span(value) do
      {:ok, seconds} when seconds > 0 or key == :min_age -> seconds
      {:ok, _zero} -> raise ArgumentError, "#{inspect(key)} must be more than no time"
      {:error, why} -> raise ArgumentError, "#{inspect(key)}: #{why}"
    end
  end

  defp check!(key, value) when key in @flags do
    if is_boolean(value), do: value, else: wrong!(key, value, "true or false")
  end

  defp check!(key, value) when key in @counts do
    if is_integer(value) and value >= 0, do: value, else: wrong!(key, value, "a count")
  end

  defp check!(key, value) when key in [:long_gc, :long_schedule, :large_heap] do
    if value == false or (is_integer(value) and value > 0),
      do: value,
      else: wrong!(key, value, "a number more than zero, or false")
  end

  defp check!(:long_message_queue, value) do
    case value do
      false ->
        false

      {over, at} when is_integer(over) and is_integer(at) and over >= 0 and over < at ->
        value

      _ ->
        wrong!(
          :long_message_queue,
          value,
          "{over_at, remarked_at} with the first the smaller, or false"
        )
    end
  end

  defp check!(key, value) when key in [:sweep_budget, :notable_work] do
    if is_number(value) and value > 0,
      do: value / 1,
      else: wrong!(key, value, "a number more than zero")
  end

  defp check!(:records, value) do
    if value in [:all, :abnormal, :none],
      do: value,
      else: wrong!(:records, value, ":all, :abnormal, or :none")
  end

  defp check!(:exit_levels, value) do
    defaults = %__MODULE__{}.exit_levels

    with true <- is_map(value) or Keyword.keyword?(value),
         given = Map.new(value),
         [] <- Map.keys(given) -- Map.keys(defaults),
         true <- Enum.all?(Map.values(given), &(&1 in @levels)) do
      Map.merge(defaults, given)
    else
      _ ->
        wrong!(
          :exit_levels,
          value,
          "a level (#{Enum.map_join(@levels, ", ", &inspect/1)}) for any of " <>
            Enum.map_join(Map.keys(defaults), ", ", &inspect/1)
        )
    end
  end

  defp check!(:trace_roots, value) do
    if is_list(value) and Enum.all?(value, &is_atom/1),
      do: value,
      else: wrong!(:trace_roots, value, "a list of modules")
  end

  defp check!(key, value) when key in [:host, :node] do
    cond do
      is_binary(value) and value != "" -> value
      is_atom(value) and value not in [nil, true, false] -> Atom.to_string(value)
      true -> wrong!(key, value, "a name")
    end
  end

  defp check!(:name, value) do
    if is_atom(value) and value not in [nil, true, false],
      do: value,
      else: wrong!(:name, value, "an atom")
  end

  defp check!(:sink, {sink, opts}) when is_atom(sink) and is_list(opts),
    do: {Sink.module(sink), opts}

  defp check!(:sink, sink) when is_atom(sink) and not is_nil(sink), do: {Sink.module(sink), []}
  defp check!(:sink, value), do: wrong!(:sink, value, "a sink, or {sink, options}")

  @spec wrong!(atom(), term(), String.t()) :: no_return()
  defp wrong!(key, value, expected) do
    raise ArgumentError, "#{inspect(key)} is #{inspect(value)}: expected #{expected}"
  end

  # What was given beside `:sink` for the planes is given to the sink. What
  # was given with it wins.
  defp with_sink(%__MODULE__{sink: {Sink.Http, opts}} = options, http),
    do: %{options | sink: {Sink.Http, Keyword.merge(http, opts)}}

  defp with_sink(options, []), do: options

  defp with_sink(%__MODULE__{sink: {sink, _}}, [{key, _} | _]) do
    raise ArgumentError,
          "#{inspect(key)} is an option of the :http sink, and the sink is #{inspect(sink)}"
  end

  defp with_names(options) do
    %{options | host: options.host || hostname(), node: options.node || Atom.to_string(node())}
  end

  # Spans are made of accounting records, and accounting records of what
  # the VM says of each exit.
  defp consistent!(options) do
    %{options | traces: options.traces and options.exits, anomalies: options.anomalies}
  end

  @doc "The name this host goes by."
  @spec hostname() :: String.t()
  def hostname do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end

  @doc "The name of one of a collector's processes or tables."
  @spec name(t() | atom(), atom()) :: atom()
  def name(%__MODULE__{name: base}, part), do: name(base, part)
  def name(base, part) when is_atom(base) and is_atom(part), do: Module.concat(base, part)
end
