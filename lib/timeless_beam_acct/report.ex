defmodule TimelessBeamAcct.Report do
  @moduledoc """
  What was collected, as text: the processes of a moment, the records of
  those that ended, and jobs as the trees of processes they were.

  These are the counterparts of the `top`, `exits`, and `trees` commands of
  timeless-acct. This module reads nothing and talks to nothing. It is
  given records and returns strings; fetching the records and printing the
  strings are the caller's.

  A table has its numbers to the right and its free text last, to the left.
  A column is as wide as the widest thing in it, so nothing is cut short
  but the last column, and that only when a `:width` is given. Widths are
  counted in characters as they are read, not in bytes.

  ## Times

  `:since` and `:until` are anything `TimelessBeamAcct.Clock.parse/2`
  accepts: `now`, `-15m`, `14:30`, `2026-09-29 14:30`, epoch seconds, a
  `DateTime`. What is relative is relative to `:now`, epoch seconds, which
  is the time it is unless it is given. Times are printed as local times.

  ## What is wrong is refused

  An option that is not one of a function's options, a time that is not a
  time, or a count that is not a count raises `ArgumentError`.
  """

  alias TimelessBeamAcct.{Clock, Event, Human, Span}

  @typedoc """
  Which records. See `filter_events/2`.
  """
  @type filter ::
          {:since, String.t() | number() | DateTime.t()}
          | {:until, String.t() | number() | DateTime.t()}
          | {:status, String.t()}
          | {:group, String.t()}
          | {:app, String.t()}
          | {:failed, boolean()}
          | {:kind, String.t() | atom()}
          | {:limit, non_neg_integer()}
          | {:now, number()}

  @typedoc """
  The processes of a moment, and the VM they were in. See `top/2`.
  """
  @type snapshot :: %{
          optional(:ts) => number(),
          optional(:host) => String.t() | nil,
          optional(:node) => String.t() | nil,
          optional(:vm) => map() | nil,
          optional(:processes) => [map()]
        }

  @filters [:since, :until, :status, :group, :app, :failed, :kind, :limit, :now]

  # The least width of each column. These are the widths the Rust prints
  # at, so a table of ordinary figures looks as its tables do.
  @pid 12
  @app 10

  ## Figures

  @doc """
  A length of time, as it is said. See `TimelessBeamAcct.Human.duration/1`.

      iex> TimelessBeamAcct.Report.human_duration(247)
      "4m07s"
  """
  @spec human_duration(number()) :: String.t()
  defdelegate human_duration(seconds), to: Human, as: :duration

  @doc """
  A size, in the units of memory. See `TimelessBeamAcct.Human.bytes/1`.

      iex> TimelessBeamAcct.Report.human_bytes(1536 * 1024 * 1024)
      "1.5 GiB"
  """
  @spec human_bytes(number()) :: String.t()
  defdelegate human_bytes(bytes), to: Human, as: :bytes

  @doc """
  A count, in thousands. See `TimelessBeamAcct.Human.count/1`.

      iex> TimelessBeamAcct.Report.human_count(12_400)
      "12.4k"
  """
  @spec human_count(number()) :: String.t()
  defdelegate human_count(count), to: Human, as: :count

  ## Records of processes that ended

  @doc """
  The records that were asked for, oldest first.

    * `:since`, `:until`: by when the process ended. Both are included.
    * `:status`: how it ended, exactly: `"killed"`.
    * `:group`: what it was, exactly: `"MyApp.Worker"`.
    * `:app`: the application it ran in, exactly.
    * `:failed`: if `true`, only those that failed. A process failed if it
      ended as anything other than `normal` or `shutdown`.
    * `:kind`: `"exit"` unless given. `:any` is every record, and another
      kind is what the VM remarked on: `"long_gc"`, `"busy_port"`.
    * `:limit`: the most recent so many of those.
    * `:now`: what `:since` and `:until` are relative to.
  """
  @spec filter_events([Event.t()], [filter()]) :: [Event.t()]
  def filter_events(events, opts \\ []) when is_list(events) do
    events |> select(options!(opts, @filters)) |> elem(0)
  end

  @doc """
  The records of processes that ended, as a table, oldest first.

      ENDED                         PID  APP         STATUS      ELAPSED      REDS   PEAK MEM  PROCESS
      2026-09-29 14:45:22     <0.512.0>  my_app      killed        394ms     48.1k    2.3 MiB  MyApp.Worker

  `ELAPSED` is how long the process lived. Of a process that was running
  before the collector was, it is how long the collector knew of it, with
  `>` in front: it lived longer than that. `REDS` and `PEAK MEM` are as of
  the last sweep that saw the process, and `-` if none did. `PROCESS` is
  what the process was, and the name it was registered under if that is
  something else.

  A record of another kind, which `kind: :any` lets in, has its kind where
  the status would be and what was measured after its process.

  Takes the options of `filter_events/2`, and:

    * `:width`: the most characters of the last column to print. 0, which
      is the default, is all of them.
  """
  @spec exits([Event.t()], [filter() | {:width, non_neg_integer()}]) :: String.t()
  def exits(events, opts \\ []) when is_list(events) do
    opts = options!(opts, [:width | @filters])
    {chosen, _window} = select(events, opts)

    columns = [
      {"ENDED", :left, 19},
      {"PID", :right, @pid},
      {"APP", :left, @app},
      {"STATUS", :left, 9},
      {"ELAPSED", :right, 8},
      {"REDS", :right, 8},
      {"PEAK MEM", :right, 9},
      {"PROCESS", :left, 0}
    ]

    rows =
      for %Event{ts_us: ts_us, fields: fields} <- chosen do
        [
          Clock.format(ts_us / 1_000_000),
          text(fields, "pid"),
          text(fields, "app"),
          text(fields, if(exit?(fields), do: "status", else: "kind")),
          elapsed(fields),
          figure(fields["reductions"], &human_count/1),
          figure(fields["peak_memory_bytes"], &human_bytes/1),
          process(fields)
        ]
      end

    table(columns, rows, count!(opts, :width, 0)) <> none(rows)
  end

  @doc """
  The records of processes that ended, totalled by what they were, as
  sa(8) does.

      2026-09-29 13:45:45 to 2026-09-29 14:45:45

         COUNT  FAILED       REDS    ELAPSED  PEAK MEM  GROUP
           113       0       5.5M      1m41s   1.2 GiB  MyApp.Worker
            79       2      13.4k      13.6s   340 MiB  fn in MyApp.Foo.bar/2
           192       2       5.5M      1m54s   1.2 GiB  (all 2 groups)

  `REDS` and `ELAPSED` are sums, and `PEAK MEM` is the largest. The groups
  that did the most work are first. `ELAPSED` has `>` in front if any of
  the group was running before the collector was: what is known of those
  is how long the collector knew of them. A figure that no record of the
  group has is `-`.

  The first line is the time the records are of: from `:since` to `:until`,
  or where one is not given, from the first of the records to the last.
  The last line is the total, and is there when there is more than one
  group.

  Takes the options of `filter_events/2`, and:

    * `:by`: `:group`, which is the default, or `:app`.
    * `:n`: the most groups to list. The total is of all of them.
    * `:width`: the most characters of the last column to print. 0, which
      is the default, is all of them.
  """
  @spec summary(
          [Event.t()],
          [
            filter()
            | {:by, :group | :app}
            | {:n, non_neg_integer()}
            | {:width, non_neg_integer()}
          ]
        ) :: String.t()
  def summary(events, opts \\ []) when is_list(events) do
    opts = options!(opts, [:by, :n, :width | @filters])

    {key, header, plural} =
      case Keyword.get(opts, :by, :group) do
        :group -> {"service", "GROUP", "groups"}
        :app -> {"app", "APP", "applications"}
        other -> raise ArgumentError, "by: #{inspect(other)} is not :group or :app"
      end

    {chosen, {since, until}} = select(events, opts)

    totals =
      chosen
      |> Enum.group_by(&text(&1.fields, key))
      |> Enum.map(fn {name, records} -> {name, total(records)} end)
      |> Enum.sort_by(fn {name, total} -> {-(total.reductions || 0), name} end)

    listed =
      case count!(opts, :n, nil) do
        nil -> totals
        n -> Enum.take(totals, n)
      end

    all =
      case totals do
        [_, _ | _] -> [{"(all #{length(totals)} #{plural})", total(chosen)}]
        _ -> []
      end

    columns = [
      {"COUNT", :right, 8},
      {"FAILED", :right, 6},
      {"REDS", :right, 9},
      {"ELAPSED", :right, 9},
      {"PEAK MEM", :right, 8},
      {header, :left, 0}
    ]

    rows =
      for {name, total} <- listed ++ all do
        [
          Integer.to_string(total.count),
          Integer.to_string(total.failed),
          figure(total.reductions, &human_count/1),
          at_least(total.elapsed, total.whole),
          figure(total.peak, &human_bytes/1),
          name
        ]
      end

    period(since, until, chosen) <> table(columns, rows, count!(opts, :width, 0))
  end

  defp total(records) do
    Enum.reduce(
      records,
      %{count: 0, failed: 0, reductions: nil, elapsed: nil, whole: true, peak: nil},
      fn %Event{fields: fields} = event, total ->
        {lived, whole} =
          case fields do
            %{"elapsed_seconds" => seconds} when is_number(seconds) -> {seconds, true}
            %{"seen_seconds" => seconds} when is_number(seconds) -> {seconds, false}
            _ -> {nil, true}
          end

        %{
          count: total.count + 1,
          failed: total.failed + if(failed?(event), do: 1, else: 0),
          reductions: sum(total.reductions, number(fields["reductions"])),
          elapsed: sum(total.elapsed, lived),
          whole: total.whole and whole,
          peak: largest(total.peak, number(fields["peak_memory_bytes"]))
        }
      end
    )
  end

  defp sum(nil, more), do: more
  defp sum(sum, nil), do: sum
  defp sum(sum, more), do: sum + more

  defp largest(nil, other), do: other
  defp largest(largest, nil), do: largest
  defp largest(largest, other), do: max(largest, other)

  defp period(since, until, chosen) do
    since = since || first_ended(chosen)
    until = until || first_ended(Enum.reverse(chosen))

    if since && until do
      "#{Clock.format(since)} to #{Clock.format(until)}\n\n"
    else
      ""
    end
  end

  defp first_ended([%Event{ts_us: ts_us} | _]), do: ts_us / 1_000_000
  defp first_ended([]), do: nil

  # The records asked for, oldest first, and the times they were asked
  # for between.
  defp select(events, opts) do
    {since, until} = window = window!(opts)
    kind = kind!(Keyword.get(opts, :kind))
    failed = flag!(opts, :failed)
    limit = count!(opts, :limit, nil)

    wanted =
      for {key, field} <- [status: "status", group: "service", app: "app"],
          value = Keyword.get(opts, key),
          do: {field, written!(key, value)}

    chosen =
      events
      |> Enum.filter(fn %Event{ts_us: ts_us, fields: fields} = event ->
        (kind == :any or fields["kind"] == kind) and
          (since == nil or ts_us >= since * 1_000_000) and
          (until == nil or ts_us <= until * 1_000_000) and
          Enum.all?(wanted, fn {field, value} -> fields[field] == value end) and
          (not failed or failed?(event))
      end)
      |> Enum.sort_by(& &1.ts_us)

    {most_recent(chosen, limit), window}
  end

  # How a process that was noticed gone ended is not known, and what is
  # not known to have failed is not counted as having failed.
  defp failed?(%Event{fields: %{"kind" => "exit", "status" => status}}),
    do: status not in ["normal", "shutdown", "unknown"]

  defp failed?(%Event{}), do: false

  defp exit?(fields), do: fields["kind"] == "exit" or not is_map_key(fields, "kind")

  defp elapsed(%{"elapsed_seconds" => seconds}) when is_number(seconds),
    do: human_duration(seconds)

  defp elapsed(%{"seen_seconds" => seconds}) when is_number(seconds),
    do: ">" <> human_duration(seconds)

  defp elapsed(_fields), do: "-"

  defp at_least(nil, _whole), do: "-"
  defp at_least(seconds, true), do: human_duration(seconds)
  defp at_least(seconds, false), do: ">" <> human_duration(seconds)

  defp process(fields) do
    group = text(fields, "service")

    named =
      case fields["name"] do
        name when is_binary(name) and name != "" and name != group -> "#{group} (#{name})"
        _ -> group
      end

    case {exit?(fields), remarked(fields)} do
      {false, remarked} when remarked != nil -> "#{named}  [#{remarked}]"
      _ -> named
    end
  end

  # What the VM measured when it remarked on a process.
  defp remarked(%{"value" => value, "unit" => "ms"}) when is_number(value),
    do: human_duration(value / 1000)

  defp remarked(%{"value" => value, "unit" => "bytes"}) when is_number(value),
    do: human_bytes(value)

  defp remarked(%{"value" => value, "unit" => unit}) when is_number(value) and is_binary(unit),
    do: "#{human_count(value)} #{unit}"

  defp remarked(%{"value" => value}) when is_number(value), do: human_count(value)
  defp remarked(_fields), do: nil

  ## Jobs

  @doc """
  Jobs, as the trees of processes they were, oldest first. A job is a
  trace.

      2026-09-29 16:32:21  5 processes over 234ms, 48.1k reductions, 1 failed  in my_app  (trace 233db4a69584b3646c1da02a132e7186)
        MyApp.Batch  234ms, 2.1k reductions, 4.0 MiB
        ├─ MyApp.Worker  27ms, 12.0k reductions, 3.4 MiB
        │  └─ fn in MyApp.Worker.fetch/1  12ms, 9.2k reductions, 36.6 MiB
        ├─ MyApp.Worker  202ms, 24.0k reductions, 2.4 MiB  [crashed: RuntimeError]
        └─ MyApp.Reporter  1ms, 800 reductions, 2.5 MiB

  The first line of a job has when its first process started, how many
  processes it was, the time from the first start to the last end, the
  reductions of all of them, how many failed, the application of its root,
  and the trace. Reductions are left out if no span has them, and failures
  if there were none.

  Each process is a line: what it was, how long it lived, its reductions
  and its peak memory if its span has them, and how it ended if it failed.
  How long it lived has `>` in front if its start is when it was first
  seen. The processes a process started are under it, in the order they
  started.

  A process whose parent is not among the spans is a root. A job has
  several roots if the process that started them is not part of it, or has
  not ended yet.

  Every job is followed by an empty line.

    * `:since`, `:until`: by when the first process of the job started.
    * `:group`: only jobs in which a process was this.
    * `:app`: only jobs with a process in this application.
    * `:failed`: if `true`, only jobs in which something failed.
    * `:limit`: the most recent so many jobs. How many earlier ones there
      are is said first.
    * `:width`: the most characters of what a process was to print. 100
      unless given, and 0 is all of them.
    * `:max_lines`: the most processes of one job to print. 60 unless
      given, and 0 is all of them. A job that is cut short says by how
      many.
    * `:now`: what `:since` and `:until` are relative to.
  """
  @spec trees(
          [Span.t()],
          [
            {:since, String.t() | number() | DateTime.t()}
            | {:until, String.t() | number() | DateTime.t()}
            | {:group, String.t()}
            | {:app, String.t()}
            | {:failed, boolean()}
            | {:limit, non_neg_integer()}
            | {:width, non_neg_integer()}
            | {:max_lines, non_neg_integer()}
            | {:now, number()}
          ]
        ) :: String.t()
  def trees(spans, opts \\ []) when is_list(spans) do
    opts =
      options!(opts, [:since, :until, :group, :app, :failed, :limit, :width, :max_lines, :now])

    {since, until} = window!(opts)
    group = opts |> Keyword.get(:group) |> then(&(&1 && written!(:group, &1)))
    app = opts |> Keyword.get(:app) |> then(&(&1 && written!(:app, &1)))
    failed = flag!(opts, :failed)
    limit = count!(opts, :limit, nil)
    width = count!(opts, :width, 100)
    max_lines = count!(opts, :max_lines, 60)

    jobs =
      spans
      |> Enum.group_by(& &1.trace_id)
      |> Enum.map(fn {trace, all} ->
        all = Enum.sort_by(all, &{&1.start_ns, &1.span_id})
        %{trace: trace, spans: all, start: hd(all).start_ns}
      end)
      |> Enum.filter(fn %{spans: all, start: start} ->
        (since == nil or start >= since * 1_000_000_000) and
          (until == nil or start <= until * 1_000_000_000) and
          (group == nil or Enum.any?(all, &(&1.name == group))) and
          (app == nil or Enum.any?(all, &(&1.service == app))) and
          (not failed or Enum.any?(all, &(&1.ok == false)))
      end)
      |> Enum.sort_by(&{&1.start, &1.trace})

    shown = most_recent(jobs, limit)

    cond do
      jobs == [] ->
        "(none)\n"

      true ->
        earlier = length(jobs) - length(shown)

        [
          if(earlier > 0, do: "(#{earlier} earlier #{plural(earlier, "job")})\n\n", else: ""),
          Enum.map(shown, &job(&1, max_lines, width))
        ]
        |> IO.iodata_to_binary()
    end
  end

  defp job(%{trace: trace, spans: all, start: start}, max_lines, width) do
    stop = all |> Enum.map(&(&1.start_ns + &1.duration_ns)) |> Enum.max()
    children = children(all)

    reductions =
      for %Span{attributes: %{"process.reductions" => reductions}} <- all,
          is_number(reductions),
          do: reductions

    failed = Enum.count(all, &(&1.ok == false))

    service =
      case Map.get(children, nil, all) do
        [%Span{service: service} | _] when is_binary(service) and service != "" -> service
        _ -> "-"
      end

    header =
      [
        Clock.format(start / 1_000_000_000),
        "  #{length(all)} #{plural(length(all), "process")} over ",
        human_duration((stop - start) / 1_000_000_000),
        if(reductions == [], do: "", else: ", #{human_count(Enum.sum(reductions))} reductions"),
        if(failed == 0, do: "", else: ", #{failed} failed"),
        "  in #{service}  (trace #{Span.hex(trace)})\n"
      ]

    [header, Enum.map(tree(all, children, max_lines, width), &["  ", &1, "\n"]), "\n"]
  end

  # The spans under each span, in the order they started. Those under
  # `nil` are the roots.
  defp children(all) do
    known = MapSet.new(all, & &1.span_id)

    Enum.group_by(all, fn %Span{span_id: id, parent_span_id: parent} ->
      # A process whose parent is not among these is a root of the job: its
      # parent is another job's, or has not ended, or its span was not
      # kept. The store writes "no parent" as all zeroes.
      if parent != id and MapSet.member?(known, parent), do: parent
    end)
  end

  defp tree(all, children, max_lines, width) do
    most = if max_lines == 0, do: length(all), else: max_lines
    {_left, lines} = draw(children, nil, "", {most, width}, [])

    cut =
      if length(all) > most, do: ["… and #{length(all) - most} more"], else: []

    Enum.reverse(lines, cut)
  end

  # The processes under `parent`, each on a line, with the lines of the
  # tree to its left. `left` is how many lines may still be drawn.
  defp draw(children, parent, prefix, {left, width}, lines) do
    below = Map.get(children, parent, [])
    last = length(below) - 1

    below
    |> Enum.with_index()
    |> Enum.reduce_while({left, lines}, fn
      _child, {0, lines} ->
        {:halt, {0, lines}}

      {span, position}, {left, lines} ->
        {branch, extend} =
          cond do
            parent == nil -> {"", ""}
            position == last -> {"└─ ", "   "}
            true -> {"├─ ", "│  "}
          end

        line = prefix <> branch <> line(span, width)

        {:cont, draw(children, span.span_id, prefix <> extend, {left - 1, width}, [line | lines])}
    end)
  end

  defp line(%Span{attributes: attributes} = span, width) do
    lived = human_duration(span.duration_ns / 1_000_000_000)

    figures =
      [
        if(attributes["process.start_known"] == false, do: ">" <> lived, else: lived),
        case attributes["process.reductions"] do
          reductions when is_number(reductions) -> "#{human_count(reductions)} reductions"
          _ -> nil
        end,
        case attributes["process.peak_memory_bytes"] do
          peak when is_number(peak) -> human_bytes(peak)
          _ -> nil
        end
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    ending =
      cond do
        span.ok != false -> ""
        span.ending in [nil, ""] -> "  [failed]"
        true -> "  [#{span.ending}]"
      end

    "#{shorten(span.name, width)}  #{figures}#{ending}"
  end

  ## The processes of a moment

  @doc """
  The processes of a moment, those doing the most first.

      2026-09-29 14:45:45  app@ohm  (182 processes)
      run queue 0   schedulers 6.1%   mem 131 MiB   48.1k reductions/s

               PID  APP           WORK%    REDS/s     MEMORY   MSGQ       AGE  PROCESS
         <0.512.0>  my_app         12.4     48.1k    2.1 MiB      0     1m55s  MyApp.Worker

  The count in the first line is the VM's, if the snapshot has it, and
  otherwise how many processes the snapshot has. A part of the second line
  that the snapshot has no value for is left out.

  `WORK%` is the process's share of all the reductions of the VM, and it
  and `REDS/s` are `-` until there are two readings of the process. `AGE`
  has `>` in front of it if the process was running before the collector
  was: it is at least that old.

    * `:sort`: `:work`, which is the default, `:memory`, `:queue`, or
      `:age`. Most first, and the processes with no figure last.
    * `:n`: how many processes to show. 20 unless given.
    * `:app`: only the processes of this application.
    * `:group`: only the processes that are this. A snapshot's process is
      known by its `:group` if it has one, and otherwise by its `:name`.
  """
  @spec top(snapshot(), [
          {:sort, :work | :memory | :queue | :age}
          | {:n, non_neg_integer()}
          | {:app, String.t()}
          | {:group, String.t()}
        ]) :: String.t()
  def top(snapshot, opts \\ []) when is_map(snapshot) do
    opts = options!(opts, [:sort, :n, :app, :group])

    by =
      case Keyword.get(opts, :sort, :work) do
        :work ->
          :reductions_per_sec

        :memory ->
          :memory_bytes

        :queue ->
          :message_queue_len

        :age ->
          :age_seconds

        other ->
          raise ArgumentError, "sort: #{inspect(other)} is not :work, :memory, :queue, or :age"
      end

    app = opts |> Keyword.get(:app) |> then(&(&1 && written!(:app, &1)))
    group = opts |> Keyword.get(:group) |> then(&(&1 && written!(:group, &1)))
    vm = Map.get(snapshot, :vm) || %{}
    all = Map.get(snapshot, :processes) || []

    rows =
      all
      |> Enum.filter(fn process ->
        (app == nil or process[:app] == app) and
          (group == nil or (process[:group] || process[:name]) == group)
      end)
      |> Enum.sort_by(fn process ->
        case process[by] do
          nil -> {true, 0, pid_order(process[:pid])}
          figure -> {false, -figure, pid_order(process[:pid])}
        end
      end)
      |> Enum.take(count!(opts, :n, 20))
      |> Enum.map(fn process ->
        [
          present(process[:pid]),
          present(process[:app]),
          figure(process[:work_pct], &Human.fixed(&1, 1)),
          figure(process[:reductions_per_sec], &human_count/1),
          figure(process[:memory_bytes], &human_bytes/1),
          figure(process[:message_queue_len], &human_count/1),
          at_least(process[:age_seconds], process[:age_known] != false),
          present(process[:name] || process[:group])
        ]
      end)

    columns = [
      {"PID", :right, @pid},
      {"APP", :left, @app},
      {"WORK%", :right, 7},
      {"REDS/s", :right, 8},
      {"MEMORY", :right, 9},
      {"MSGQ", :right, 5},
      {"AGE", :right, 8},
      {"PROCESS", :left, 0}
    ]

    count = vm[:processes] || length(all)

    first =
      [
        Clock.format(Map.get(snapshot, :ts) || 0),
        snapshot[:node] || snapshot[:host],
        "(#{count} #{plural(count, "process")})"
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("  ")

    second =
      [
        vm[:run_queue] && "run queue #{vm[:run_queue]}",
        vm[:scheduler_util_pct] && "schedulers #{Human.fixed(vm[:scheduler_util_pct], 1)}%",
        vm[:memory_total_bytes] && "mem #{human_bytes(vm[:memory_total_bytes])}",
        vm[:reductions_per_sec] && "#{human_count(vm[:reductions_per_sec])} reductions/s"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("   ")

    IO.iodata_to_binary([
      first,
      "\n",
      if(second == "", do: "", else: [second, "\n"]),
      "\n",
      table(columns, rows, 0),
      none(rows)
    ])
  end

  # Pids in the order of their numbers, not of their digits.
  defp pid_order(pid) when is_binary(pid) do
    {~r/\d+/ |> Regex.scan(pid) |> Enum.map(fn [digits] -> String.to_integer(digits) end), pid}
  end

  defp pid_order(pid), do: {[], pid}

  ## Tables

  # A line of headers and a line for each row. Every column but the last
  # is as wide as the widest thing in it, and no narrower than it is asked
  # to be. The last is free text, and is cut short if it is longer than
  # `width`.
  defp table(columns, rows, width) do
    {fixed, [{last, _, _}]} = Enum.split(columns, -1)
    rows = Enum.map(rows, &List.update_at(&1, -1, fn free -> shorten(free, width) end))

    widths =
      fixed
      |> Enum.with_index()
      |> Enum.map(fn {{header, _align, least}, index} ->
        rows
        |> Enum.map(&String.length(Enum.at(&1, index)))
        |> Enum.max(fn -> 0 end)
        |> max(String.length(header))
        |> max(least)
      end)

    headers = Enum.map(fixed, &elem(&1, 0)) ++ [last]

    [headers | rows]
    |> Enum.map(fn cells ->
      {cells, [free]} = Enum.split(cells, -1)

      [fixed, widths, cells]
      |> Enum.zip_with(fn
        [{_header, :left, _least}, width, cell] -> String.pad_trailing(cell, width)
        [{_header, :right, _least}, width, cell] -> String.pad_leading(cell, width)
      end)
      |> Kernel.++([free])
      |> Enum.join("  ")
      |> String.trim_trailing()
      |> Kernel.<>("\n")
    end)
    |> IO.iodata_to_binary()
  end

  defp none([]), do: "(none)\n"
  defp none(_rows), do: ""

  # As the Rust does: `width` characters, the last of which says that
  # there were more.
  defp shorten(text, 0), do: text

  defp shorten(text, width) do
    if String.length(text) <= width do
      text
    else
      String.slice(text, 0, width - 1) <> "…"
    end
  end

  defp text(fields, key), do: present(fields[key])

  defp present(nil), do: "-"
  defp present(""), do: "-"
  defp present(value) when is_binary(value), do: value
  defp present(value), do: to_string(value)

  defp figure(value, format) when is_number(value), do: format.(value)
  defp figure(_value, _format), do: "-"

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  defp plural(1, word), do: word
  defp plural(_count, "process"), do: "processes"
  defp plural(_count, word), do: word <> "s"

  defp most_recent(all, nil), do: all
  defp most_recent(_all, 0), do: []
  defp most_recent(all, limit), do: Enum.take(all, -limit)

  ## Options

  defp options!(opts, known) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "#{inspect(opts)} is not a list of options"
    end

    case Keyword.keys(opts) -- known do
      [] ->
        opts

      [unknown | _] ->
        raise ArgumentError,
              "#{inspect(unknown)} is not an option here: the options are " <>
                Enum.map_join(known, ", ", &inspect/1)
    end
  end

  defp window!(opts) do
    now =
      case Keyword.get(opts, :now) do
        nil -> Clock.now()
        now when is_number(now) -> now
        other -> raise ArgumentError, "now: #{inspect(other)} is not a time in epoch seconds"
      end

    since = moment!(Keyword.get(opts, :since), now)
    until = moment!(Keyword.get(opts, :until), now)

    if since && until && until < since do
      raise ArgumentError, ":until is before :since"
    end

    {since, until}
  end

  defp moment!(nil, _now), do: nil

  defp moment!(written, now)
       when is_binary(written) or is_number(written) or is_struct(written, DateTime),
       do: Clock.parse!(written, now)

  defp moment!(other, _now), do: raise(ArgumentError, "#{inspect(other)} is not a time")

  defp kind!(nil), do: "exit"
  defp kind!(:any), do: :any
  defp kind!(kind) when is_binary(kind), do: kind
  defp kind!(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp kind!(other), do: raise(ArgumentError, "kind: #{inspect(other)} is not a kind of record")

  defp flag!(opts, key) do
    case Keyword.get(opts, key, false) do
      flag when is_boolean(flag) -> flag
      nil -> false
      other -> raise ArgumentError, "#{key}: #{inspect(other)} is not true or false"
    end
  end

  defp count!(opts, key, default) do
    case Keyword.get(opts, key) do
      nil -> default
      count when is_integer(count) and count >= 0 -> count
      other -> raise ArgumentError, "#{key}: #{inspect(other)} is not a count"
    end
  end

  defp written!(_key, value) when is_binary(value), do: value
  # A module is named as it is written: `MyApp.Worker`, `:code_server`.
  defp written!(_key, value) when is_atom(value),
    do: value |> inspect() |> String.trim_leading(":")

  defp written!(key, other), do: raise(ArgumentError, "#{key}: #{inspect(other)} is not a name")
end
