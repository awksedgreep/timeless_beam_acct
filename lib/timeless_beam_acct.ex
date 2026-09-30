defmodule TimelessBeamAcct do
  @moduledoc """
  Process accounting history for a running BEAM, in Timeless.

  A collector records:

    * what **sar** would record of a node: schedulers, run queues, memory,
      garbage collection, I/O, and how near the node is to its limits
      (`beam_vm_*`);
    * a set of series for every **application** (`beam_app_*`), and for
      every **group** of processes that are the same thing (`beam_group_*`);
    * a set of series for every **process** that someone named, or that is
      large (`beam_proc_*`);
    * an **accounting record for every process that ends**, however
      briefly it lived, with what it was and why it ended;
    * a **trace for every job**: each request, each task, as the tree of
      processes it was;
    * what **the VM remarks on**: a garbage collection that took long, a
      queue that grew long.

  ## Starting one

  Among the children of a supervisor:

      children = [
        {TimelessBeamAcct, sink: :http, metrics_url: "http://127.0.0.1:8428"}
      ]

  or from the configuration, with `start: true`
  (`TimelessBeamAcct.Application`), or in a node that is already running
  and was built without it (`TimelessBeamAcct.Remote`).

  `TimelessBeamAcct.Options` lists what a collector can be told.

  ## Looking, from a shell on the node

      TimelessBeamAcct.check()
      TimelessBeamAcct.diagnostics()
      TimelessBeamAcct.top()
      TimelessBeamAcct.top(sort: :memory, n: 10)
      TimelessBeamAcct.exits(since: "-5m", failed: true)
      TimelessBeamAcct.exits(since: "-1h", summary: true, by: :app)
      TimelessBeamAcct.trees(failed: true)

  These read what the collector has in memory: the processes as of the
  last sweep, and the last `:history` records and spans. The history is
  in the stores, and a canvas is how it is looked at.
  """

  alias TimelessBeamAcct.{
    Clock,
    Collector,
    History,
    Options,
    Processes,
    Report,
    Tracer,
    Writer
  }

  @type name :: atom()

  @version Mix.Project.config()[:version]

  @doc """
  The version of the collector: `"#{@version}"`.

  For whatever reads a collector from outside it, to know what it is
  reading.
  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  A collector, as a child of a supervisor.
  """
  @spec child_spec(keyword() | Options.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    options = Options.new!(opts)

    %{
      id: options.name,
      start: {__MODULE__, :start_link, [options]},
      type: :supervisor
    }
  end

  @doc """
  Start a collector, linked to the process that calls this.

  Raises `ArgumentError` for an option that is wrong, and returns
  `{:error, reason}` for a sink that cannot be made.

  Returns `:ignore`, and starts nothing, where the configuration says
  `config :timeless_beam_acct, start: false`. That is how a collector that
  is among the children of a supervisor is kept from running with the
  application's tests: it is a child wherever the application is
  started, and the configuration is what differs from one environment to
  the next.
  """
  @spec start_link(keyword() | Options.t()) :: Supervisor.on_start() | :ignore
  def start_link(opts \\ []) do
    options = Options.new!(opts)

    if Application.get_env(:timeless_beam_acct, :start) == false,
      do: :ignore,
      else: TimelessBeamAcct.Supervisor.start_link(options)
  end

  @doc """
  Stop a collector. What ended since the last sweep is accounted, and what
  the sink has waiting is flushed, before this returns.

  A collector that was started with the application, by `start: true`,
  stays stopped until the application is started again. One that is among
  the children of a supervisor is that supervisor's to stop: stopped
  here, it is started again, as any child of a supervisor is.
  """
  @spec stop(name(), timeout()) :: :ok
  def stop(name \\ __MODULE__, timeout \\ 30_000) do
    ours = TimelessBeamAcct.Application.Supervisor

    if is_pid(Process.whereis(ours)) and
         Enum.any?(Supervisor.which_children(ours), &(elem(&1, 0) == name)) do
      :ok = Supervisor.terminate_child(ours, name)
      :ok = Supervisor.delete_child(ours, name)
    else
      Supervisor.stop(Options.name(name, :Supervisor), :normal, timeout)
    end
  end

  @doc """
  Whether a collector of this name is running.
  """
  @spec running?(name()) :: boolean()
  def running?(name \\ __MODULE__),
    do: is_pid(Process.whereis(Options.name(name, :Collector)))

  @doc """
  What a collector has to say of itself, or `nil` if none is running.

    * `:options`: what it was told
    * `:exits`: `:heard`, `:not_asked_for`, or `:unavailable`
    * `:sweep`: the last sweep, how many processes it found, and how long it took
    * `:tracer`: what the tracer has counted
    * `:dropped`: records and ticks let go
    * `:vm`: the node, as of the last reading
    * `:writer`: the sink, and how it is doing
  """
  @spec status(name()) :: map() | nil
  def status(name \\ __MODULE__) do
    with %{} = status <- Collector.status(name) do
      Map.put(status, :writer, Writer.status(name))
    end
  end

  @doc """
  Take a reading now, and wait until it has been taken.
  """
  @spec tick(name()) :: :ok
  def tick(name \\ __MODULE__), do: Collector.tick(name)

  @doc """
  Hand the sink what it has waiting, and wait until it has been handed over.
  """
  @spec flush(name()) :: :ok | {:error, term()}
  def flush(name \\ __MODULE__), do: Writer.flush(name)

  ## Looking

  @doc """
  The processes as of the last sweep, and the node they are in: what
  `top/1` prints.

  A node may have a hundred thousand processes, and whoever draws it
  wants the first few of them:

    * `:most`: only so many by what they do, so many by what they hold,
      and so many by what they have waiting
    * `:group`, `:app`: only those of a group, or of an application
  """
  @spec snapshot(name(), keyword()) :: Report.snapshot()
  def snapshot(name \\ __MODULE__, opts \\ []) do
    status = Collector.status(name) || %{}
    vm = Map.get(status, :vm, %{})
    options = Map.get(status, :options)

    %{
      ts: get_in(status, [:sweep, :at]) || Clock.now(),
      host: options && options.host,
      node: (options && options.node) || Atom.to_string(node()),
      vm: Map.put_new(vm, :processes, :erlang.system_info(:process_count)),
      processes: Processes.snapshot(Options.name(name, :Processes), vm[:reductions_per_sec], opts)
    }
  end

  @doc """
  Print the processes that are doing the most, as of the last sweep.

    * `:sort`: `:work` (the default), `:memory`, `:queue`, or `:age`
    * `:n`: how many, 20 unless told
    * `:app`, `:group`: only those of an application, or of a group
    * `:name`: the collector to ask, if it was started under a name
  """
  @spec top(keyword()) :: :ok
  def top(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    name |> snapshot() |> Report.top(opts) |> IO.write()
  end

  @doc """
  Print the processes that ended, from the records kept in memory.

    * `:since`, `:until`: by when the process ended: `"-15m"`, `"14:30"`,
      `"2026-09-29 03:12"`, epoch seconds, a `DateTime`
    * `:status`, `:group`, `:app`: exactly
    * `:failed`: only those that failed
    * `:kind`: `"exit"` unless told; `:any`, or `"long_gc"` and the like,
      for what the VM remarked on
    * `:limit`: the most recent
    * `:summary`: totals, by `:by`, which is `:group` or `:app`, as sa(8)
      does
    * `:width`: of the terminal
    * `:name`: the collector to ask
  """
  @spec exits(keyword()) :: :ok
  def exits(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    {summary, opts} = Keyword.pop(opts, :summary, false)
    records = History.events(name)

    if summary do
      records |> Report.summary(opts) |> IO.write()
    else
      records |> Report.exits(Keyword.delete(opts, :by)) |> IO.write()
    end
  end

  @doc """
  Print jobs, as the trees of processes they were, from the spans kept in
  memory.

    * `:since`, `:until`: by when the job started
    * `:group`, `:app`: jobs in which a process of that group, or of that
      application, took part
    * `:failed`: jobs in which something failed
    * `:limit`: the most recent
    * `:width`, `:max_lines`
    * `:name`: the collector to ask
  """
  @spec trees(keyword()) :: :ok
  def trees(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    name |> History.spans() |> Report.trees(opts) |> IO.write()
  end

  @doc """
  The records kept in memory, oldest first, chosen as `exits/1` chooses.
  """
  @spec records(keyword()) :: [TimelessBeamAcct.Event.t()]
  def records(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    name |> History.events() |> Report.filter_events(opts)
  end

  @doc """
  The spans kept in memory, oldest first.
  """
  @spec spans(name()) :: [TimelessBeamAcct.Span.t()]
  def spans(name \\ __MODULE__), do: History.spans(name)

  @doc """
  The last reading: the samples the sink was last given, a metric at a
  time, as `{metric, epoch_seconds, [{labels, value}]}`.

  This is the node as it is now, in the figures the stores have of every
  other moment, for whatever draws it: `mix timeless_beam_acct.watch`
  does. The labels are those of the series, without the host and the node
  that the sink adds.

  A reading of the node alone leaves the samples of the processes as they
  were, so each metric says when it was read. None are kept by a
  collector told `history: 0`.
  """
  @spec reading(name()) :: [History.read()]
  def reading(name \\ __MODULE__), do: History.reading(name)

  ## What this node lets a collector see

  @doc """
  Print what this node lets a collector see, and what to do about what it
  does not.

  With options, it is said of a collector told those. With none, of the
  one that is running, or of one told nothing.
  """
  @spec check(keyword()) :: :ok
  def check(opts \\ []) do
    lines = checked(opts)
    width = lines |> Enum.map(fn {what, _} -> String.length(what) end) |> Enum.max()

    Enum.each(lines, fn
      {"", ""} -> IO.puts("")
      {what, how} -> IO.puts(String.pad_trailing(what, width + 3) <> how)
    end)
  end

  @doc """
  What `check/1` prints, as pairs.
  """
  @spec checked(keyword()) :: [{String.t(), String.t()}]
  def checked(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    status = status(name)

    options =
      cond do
        opts != [] -> Options.new!(opts)
        status -> status.options
        true -> Options.new!([])
      end

    release = :erlang.system_info(:otp_release) |> List.to_string()

    [
      {"trace sessions",
       available(Tracer.available?(), "needs OTP 27, and this is OTP #{release}")},
      {"word of each exit", exits(options, status)},
      {"what the VM remarks on", remarks(options, release)},
      {"process iterator",
       available(
         function_exported?(:erlang, :processes_iterator, 0),
         "needs OTP 28: a sweep lists every process before it reads any"
       )},
      {"one key of a dictionary",
       available(one_key?(), "needs OTP 26.2: a process is asked for its whole dictionary, once")},
      {"scheduler wall time", on(:erlang.statistics(:scheduler_wall_time) != :undefined)},
      {"microstate accounting", if(options.msacc, do: "asked for", else: "not asked for")},
      {"processes",
       "#{:erlang.system_info(:process_count)} of #{:erlang.system_info(:process_limit)}"},
      {"collector", collector(status)},
      {"", ""}
      | sink(options, if(opts == [], do: status))
    ]
  end

  @doc """
  Print what someone who is asked about a problem will ask for: the
  versions, what `check/1` says, what the collector was told, and what it
  has counted.

  It is for pasting into a report. A bearer token is not printed.

  The options are those of `check/1`.
  """
  @spec diagnostics(keyword()) :: :ok
  def diagnostics(opts \\ []), do: opts |> diagnosed() |> IO.write()

  @doc """
  What `diagnostics/1` prints.
  """
  @spec diagnosed(keyword()) :: String.t()
  def diagnosed(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    status = status(name)
    lines = checked(opts)
    width = lines |> Enum.map(fn {what, _} -> String.length(what) end) |> Enum.max()

    checks =
      Enum.map(lines, fn
        {"", ""} -> "\n"
        {what, how} -> String.pad_trailing(what, width + 3) <> how <> "\n"
      end)

    IO.iodata_to_binary([
      "timeless_beam_acct #{@version}\n",
      "Elixir #{System.version()}, OTP #{System.otp_release()} ",
      "(erts #{:erlang.system_info(:version)}), ",
      "#{System.schedulers_online()} schedulers, ",
      "#{:erlang.system_info(:system_architecture)}\n",
      "node #{node()}, up #{Report.human_duration(uptime())}\n\n",
      checks,
      "\n",
      told(status),
      counted(status)
    ])
  end

  defp uptime, do: elem(:erlang.statistics(:wall_clock), 0) / 1000

  defp told(nil), do: ""

  # What it was told that a collector told nothing would not have been.
  defp told(%{options: options}) do
    unless_told = Options.new!(name: options.name)

    given =
      for {key, value} <- Map.from_struct(options),
          key not in [:name, :host, :node],
          value != Map.fetch!(unless_told, key),
          do: "  #{key}: #{inspect(unsaid(key, value))}\n"

    case given do
      [] -> "told nothing but where it is\n\n"
      given -> ["told\n", Enum.sort(given), "\n"]
    end
  end

  defp unsaid(:sink, {module, opts}) do
    {module,
     Enum.map(opts, fn
       {:token, _} -> {:token, "(given)"}
       other -> other
     end)}
  end

  defp unsaid(_key, value), do: value

  defp counted(nil), do: ""

  defp counted(status) do
    dropped = Map.get(status, :dropped, %{records: 0, ticks: 0})

    tracer =
      case Map.get(status, :tracer) do
        %{} = counts ->
          "tracer     #{if counts.listening, do: "listening", else: "not listening"}, " <>
            "#{counts.spawns} started, #{counts.exits} ended, " <>
            "stopped listening #{counts.suspensions} times, #{counts.waiting} waiting, " <>
            "#{counts.remarks} remarks and #{counts.remarks_dropped} let go\n"

        _ ->
          "tracer     none\n"
      end

    writer =
      case Map.get(status, :writer) do
        %{} = writer ->
          "writer     #{writer.written} ticks written, #{writer.failed} failed" <>
            if(writer.last_error, do: "; the last failure: #{writer.last_error}", else: "") <>
            "\n"

        _ ->
          "writer     none\n"
      end

    [
      "let go     #{dropped.records} records, #{dropped.ticks} ticks\n",
      tracer,
      writer
    ]
  end

  defp available(true, _otherwise), do: "available"
  defp available(false, otherwise), do: "unavailable: " <> otherwise

  defp on(true), do: "on"
  defp on(false), do: "off"

  defp exits(%Options{exits: false}, _status), do: "not asked for"

  defp exits(_options, %{tracer: %{listening: true} = counts}),
    do: "heard: #{counts.spawns} started and #{counts.exits} ended so far"

  defp exits(_options, %{tracer: %{listening: false} = counts}),
    do: "not listening: too much was waiting (#{counts.suspensions} times so far)"

  defp exits(_options, _status) do
    if Tracer.available?(),
      do: "will be heard",
      else: "unavailable: processes that end are noticed gone at the next sweep"
  end

  defp remarks(%Options{anomalies: false}, _release), do: "not asked for"

  defp remarks(%Options{exits: false}, _release),
    do: "not heard: they come with word of each exit"

  # A trace session has a system monitor of its own a release after there
  # were trace sessions.
  defp remarks(_options, release) do
    if Tracer.remarks?(),
      do: "heard",
      else: "unavailable: needs OTP 28, and this is OTP #{release}"
  end

  defp collector(nil), do: "not running"

  defp collector(%{sweep: sweep}) do
    "running: a sweep of #{sweep.processes} processes took " <>
      "#{Report.human_duration(sweep.seconds)}, every #{Report.human_duration(sweep.interval)}; " <>
      "#{sweep.reported} have series of their own"
  end

  defp collector(_status), do: "running"

  defp one_key? do
    :erlang.process_info(self(), [{:dictionary, :"$initial_call"}])
    true
  rescue
    ArgumentError -> false
  end

  # Of the sink that is running, unless another was asked about. `status`
  # is that of the collector whose sink it is, or `nil`.
  defp sink(%Options{sink: {module, opts}}, status) do
    running =
      case status do
        %{writer: %{} = writer} ->
          [
            {"sink", writer.sink},
            {"written",
             "#{writer.written} ticks, #{writer.failed} failed" <>
               if(writer.failing, do: "; failing now: #{writer.last_error}", else: "")}
          ]

        _ ->
          []
      end

    case module.init(opts) do
      {:ok, sink} ->
        described = if running == [], do: [{"sink", module.describe(sink)}], else: running
        described ++ reached(module, sink)

      {:error, reason} when running == [] ->
        [{"sink", "cannot be made: #{said(reason)}"}]

      # The one that is running was made. One like it could not be made
      # now: what it writes to has gone since.
      {:error, reason} ->
        running ++ [{"made again", "it could not be: #{said(reason)}"}]
    end
  end

  defp said(reason) when is_binary(reason), do: reason
  defp said(reason), do: inspect(reason, limit: 10)

  defp reached(module, sink) do
    if function_exported?(module, :check, 1) do
      for {what, where, result} <- module.check(sink) do
        case result do
          {:ok, said} -> {"#{what} plane", "#{where}  #{said}"}
          {:error, why} -> {"#{what} plane", "#{where}  #{why}"}
        end
      end
    else
      []
    end
  end
end
