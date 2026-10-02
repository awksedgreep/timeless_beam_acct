defmodule TimelessBeamAcct.Watch do
  @moduledoc """
  Watching a node in a terminal: now, and at any moment the store holds.

  This is `timeless-acct watch`, of a node: the same screen, and the same
  keys. Now is what the collector in the node last read, asked of the
  node. Every other moment is read from the store the collector writes
  to.

      mix timeless_beam_acct.watch app@ohm --cookie secret

  ## What it is told

  | option | | |
  |---|---|---|
  | `:node` | | the node to watch, which has been connected to. Without one, now is the last moment in the store |
  | `:name` | `TimelessBeamAcct` | the name the collector was started under |
  | `:metrics_url`, `:logs_url`, `:traces_url` | those the collector writes to | the planes to read |
  | `:token`, `:metrics_token`, `:logs_token`, `:traces_token` | those the collector writes with | tokens that may read |
  | `:store_node`, `:host` | those of the collector | whose series are read, of a store that has several nodes' |
  | `:at` | `"now"` | the moment to begin at |
  | `:view` | `:groups` | `:groups`, `:processes`, `:jobs`, or `:exits` |
  | `:refresh` | `2` | seconds between looks at now |
  | `:print` | | `"120x40"`: draw the screen once, as text, and return |

  ## Where the other moments are

  A collector with the `:http` sink writes to the planes, and says where
  they are: those are read, unless others are given. A collector with any
  other sink writes to nothing that can be asked here, and what is
  watched is now, with the last processes to end that the collector keeps
  in memory.
  """

  alias TimelessBeamAcct.{Clock, Human}
  alias TimelessBeamAcct.Watch.{Canvas, Data, Live, Memory, Planes, State, Store, Terminal, View}
  alias TimelessBeamAcct.Watch.View.Detail

  # How far back a series' last sample may be for the series to be there,
  # in samples of the store: a process that has ended has none.
  @within 3.0
  # How far back a row's history goes.
  @history 600.0
  # How far back jobs and exits are looked for.
  @recent 900.0
  @rows 200
  # How long the timeline is kept before it is read again, while now is
  # what is looked at; and how long the pace of the store is.
  @timeline_for 10_000
  @pace_for 60_000
  @spacing 10.0

  @type t :: %__MODULE__{}

  defstruct store: nil,
            live: nil,
            state: nil,
            snapshot: %Data{},
            detail: %Detail{},
            width: 100,
            # How far back a series' last sample may be, at the moment
            # looked at.
            within: @within * @spacing,
            # When the timeline was read, and of which stretch.
            timeline_read: nil,
            # When the pace of the store was found out, and what it is.
            paced: nil,
            # What the node was last asked, and what it answered.
            asked: nil,
            # How wide the terminal is.
            columns: 100,
            refresh: 2_000

  @doc """
  Watch, until `q` is pressed. `{:error, why}` if there is nothing to
  watch, or no terminal to watch it in.
  """
  @spec run(keyword()) :: :ok | {:error, String.t()}
  def run(opts) do
    with {:ok, watch} <- new(opts) do
      case opts[:print] do
        nil -> interactive(watch)
        size -> print(watch, size)
      end
    end
  end

  ## Setting out

  @doc false
  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(opts) do
    now = Clock.now()

    with {:ok, refresh} <- refresh(opts[:refresh] || 2),
         {:ok, view} <- view(opts[:view] || :groups),
         {:ok, at} <- moment(opts[:at] || "now", now),
         {:ok, live, status} <- live(opts),
         {:ok, store, said} <- store(opts, live, status) do
      options = status && status[:options]

      state = %{State.new(at, @spacing) | tab: view, message: said}

      {:ok,
       %__MODULE__{
         store: store,
         live: live,
         state: state,
         refresh: refresh,
         detail: %Detail{
           now: now,
           node: label(store, live, options),
           stored: not match?(%Memory{}, store)
         },
         paced: options && {nil, {options.interval / 1, options.process_interval / 1}}
       }}
    end
  end

  defp refresh(seconds) when is_number(seconds) and seconds >= 1, do: {:ok, round(seconds * 1000)}
  defp refresh(_other), do: {:error, "--refresh is a number of seconds, and at least one"}

  defp view(view) when view in [:groups, :processes, :jobs, :exits], do: {:ok, view}

  defp view(other),
    do: {:error, "--view is #{other}: expected groups, processes, jobs, or exits"}

  defp moment("now", _now), do: {:ok, nil}
  defp moment(written, now), do: Clock.parse(written, now)

  defp live(opts) do
    case opts[:node] do
      nil ->
        {:ok, nil, nil}

      node ->
        live = %Live{node: node, name: opts[:name] || TimelessBeamAcct}
        with {:ok, status} <- Live.status(live), do: {:ok, live, status}
    end
  end

  @plane_keys [:metrics_url, :logs_url, :traces_url]
  @token_keys [:token, :metrics_token, :logs_token, :traces_token]

  # The store: the planes that were said, or those the collector writes
  # to, or what it keeps in memory.
  defp store(opts, live, status) do
    case opts[:store] do
      nil -> said_store(opts, live, status)
      # One that was made already: a test has one.
      store -> {:ok, store, nil}
    end
  end

  defp said_store(opts, live, status) do
    given = Keyword.take(opts, @plane_keys ++ @token_keys ++ [:host, :timeout])
    options = status && status[:options]

    written_to =
      case options do
        %{sink: {TimelessBeamAcct.Sink.Http, sink}} ->
          Keyword.take(sink, @plane_keys ++ @token_keys)

        _ ->
          nil
      end

    who =
      case {opts[:store_node], options} do
        {node, _} when is_binary(node) -> [node: node]
        {nil, %{node: node, host: host}} -> [node: node, host: host]
        _ -> []
      end

    cond do
      Enum.any?(@plane_keys, &Keyword.has_key?(given, &1)) or live == nil ->
        if live == nil and not Enum.any?(@plane_keys, &Keyword.has_key?(given, &1)) do
          {:error,
           "Which node, or which store? A node is named first, and a store with --metrics-url."}
        else
          with {:ok, planes} <- Planes.new(Keyword.merge(who, given)),
               {:ok, planes} <- Planes.reach(planes) do
            {:ok, planes, nil}
          end
        end

      written_to ->
        # What the collector was not told, it writes where a collector
        # writes unless told.
        told = [defaults: true] |> Keyword.merge(who) |> Keyword.merge(written_to)

        with {:ok, planes} <- Planes.new(Keyword.merge(told, given)),
             {:ok, planes} <- Planes.reach(planes) do
          {:ok, planes, nil}
        else
          # The node is there to be watched, whatever has become of what
          # it writes to.
          {:error, why} -> {:ok, %Memory{live: live}, "Only now: #{why}"}
        end

      match?(%{sink: {TimelessBeamAcct.Sink.Timeless, _}}, options) ->
        {:ok, %Memory{live: live},
         "Only now: what a collector writes to the stores in its node is not read here yet."}

      true ->
        {:ok, %Memory{live: live},
         "Only now: the collector writes to nothing that can be asked for another moment."}
    end
  end

  defp label(_store, %Live{node: node}, _options), do: Atom.to_string(node)
  defp label(%Planes{node: node}, _live, _options), do: node || ""
  defp label(_store, _live, _options), do: ""

  ## Reading

  # Read the moment looked at.
  @doc false
  @spec read_moment(t()) :: t()
  def read_moment(%__MODULE__{} = watch) do
    {range, store} = Store.range(watch.store)

    watch = %{
      watch
      | store: store,
        detail: %{watch.detail | now: Clock.now(), range: range, error: nil}
    }

    watch = pace(watch)

    watch = if State.live?(watch.state), do: ask(watch), else: watch

    {snapshot, error} =
      case {watch.state.at, watch.live} do
        {nil, nil} -> newest(watch)
        {nil, _live} -> now(watch)
        {at, _} -> stored(watch, at)
      end

    read_detail(%{watch | snapshot: snapshot, detail: %{watch.detail | error: error}})
  end

  # Now: what the collector last read; or, with no node to ask, or a
  # collector that keeps no reading, the last moment in the store.
  defp now(%__MODULE__{} = watch) do
    case watch.asked do
      {_what, {:ok, %{series: series, processes: processes, at: at}}} when series != %{} ->
        {Data.read(at, series, processes), nil}

      {_what, {:ok, %{processes: processes, at: at}}} ->
        {stored, error} = newest(watch)
        {%{stored | at: max(at, stored.at), processes: processes}, error}

      {_what, {:error, why}} ->
        {%Data{at: watch.detail.now}, why}
    end
  end

  # How many processes a node is asked for: the first so many by what
  # they do, by what they hold, and by what they have waiting.
  @most 300

  # Ask the node, if it has read anything since it was last asked, or is
  # asked for other processes than it was.
  defp ask(%__MODULE__{live: nil} = watch), do: watch

  defp ask(%__MODULE__{live: live, state: state} = watch) do
    which =
      case state.within do
        {:group, group} -> [most: @most, group: group]
        {:app, app} -> [most: @most, app: app]
        nil -> [most: @most]
      end

    what = {Live.stamp(live), which}

    case watch.asked do
      {^what, {:ok, _}} -> watch
      _ -> %{watch | asked: {what, Live.read(live, watch.within, which)}}
    end
  end

  defp newest(watch) do
    case watch.detail.range do
      {_first, last} -> stored(watch, last)
      nil -> {%Data{at: watch.detail.now}, nil}
    end
  end

  defp stored(watch, at) do
    case Store.at(watch.store, at, watch.within) do
      {:ok, series} -> {Data.read(at, series), nil}
      {:error, why} -> {%Data{at: at}, why}
    end
  end

  # Keep the store's pace. A step in time is from one of its samples to
  # the next, and a series is there at a moment if it has a sample in the
  # few before it: of a store sampled every second as of one sampled every
  # minute.
  defp pace(%__MODULE__{} = watch) do
    until = until(watch)
    ms = System.monotonic_time(:millisecond)

    {found, watch} =
      case watch.paced do
        # What the collector was told, which needs no finding out.
        {nil, told} ->
          {told, watch}

        {at, found} when ms - at < @pace_for ->
          {found, watch}

        _ ->
          found = Store.spacing(watch.store, until)
          {found, %{watch | paced: {ms, found}}}
      end

    {finest, coarsest} =
      case found do
        {nil, nil} -> {@spacing, @spacing}
        {a, nil} -> {a, a}
        {nil, b} -> {b, b}
        {a, b} -> {min(a, b), max(a, b)}
      end

    %{
      watch
      | state: %{watch.state | step: max(finest, 1.0)},
        within: @within * max(coarsest, 1.0)
    }
  end

  # Up to the moment looked at; and now, as far as the store goes.
  defp until(%__MODULE__{state: state, detail: detail}) do
    case {state.at, detail.range} do
      {nil, {_first, last}} -> last
      {nil, nil} -> detail.now
      {at, _} -> at
    end
  end

  # Read the timeline: how busy the schedulers were, and what went wrong,
  # over a stretch that has the moment looked at in it.
  defp read_timeline(%__MODULE__{state: state, detail: detail} = watch) do
    span = State.window(state)

    last =
      case detail.range do
        {_first, last} -> last
        nil -> detail.now
      end

    # Up to now, if the moment is within the stretch before now; and
    # around the moment, if it is further back than that.
    to =
      case state.at do
        nil -> detail.now
        at when at < last - span -> min(at + span / 2, last)
        _ -> last
      end

    # A stretch is drawn a column to so many seconds; a stretch that has
    # moved by less than a column is the same stretch.
    column = span / 100
    to = Float.ceil(to / column) * column
    window = {to - span, to}
    ms = System.monotonic_time(:millisecond)

    fresh =
      case watch.timeline_read do
        {at, ^window} -> not State.live?(state) or ms - at < @timeline_for
        _ -> false
      end

    if fresh do
      watch
    else
      {timeline, step} = Store.timeline(watch.store, elem(window, 0), to)

      {incidents, store} =
        Store.incidents(watch.store, elem(window, 0), to, max(watch.columns - 2, 1))

      %{
        watch
        | store: store,
          timeline_read: {ms, window},
          detail: %{
            detail
            | timeline: timeline,
              timeline_step: step,
              incidents: incidents,
              window: window
          }
      }
    end
  end

  # Read what goes with the moment: the picked row's history, and what
  # ran and what ended in the minutes before.
  @doc false
  @spec read_detail(t()) :: t()
  def read_detail(%__MODULE__{} = watch) do
    watch = read_timeline(%{watch | detail: %{watch.detail | now: Clock.now()}})
    %__MODULE__{state: state, detail: detail, store: store} = watch
    until = until(watch)

    detail = %{
      detail
      | history: [],
        history_of: "",
        history_span: @history,
        history_until: until,
        step: state.step
    }

    # The quarter of an hour before; and, when something is looked for,
    # as far back as the timeline shows.
    reach = %{
      until: if(State.live?(state), do: max(until, detail.now), else: until),
      span: if(State.looking?(state), do: max(State.window(state), @recent), else: @recent),
      limit: @rows
    }

    case state.tab do
      tab when tab in [:groups, :processes] ->
        rows =
          if tab == :groups,
            do: State.groups(state, watch.snapshot),
            else: State.processes(state, watch.snapshot)

        state = State.clamp(state, length(rows))

        detail =
          case View.history_of(state, watch.snapshot) do
            {metric, key, want, title, kind} ->
              %{
                detail
                | history: Store.history(store, metric, key, want, until - @history, until),
                  history_of: title,
                  history_kind: kind
              }

            nil ->
              detail
          end

        %{watch | state: state, detail: detail}

      :jobs ->
        case Store.jobs(store, reach, watch.width, &State.wants?(state, [&1.name, &1.app])) do
          {:ok, jobs} -> %{watch | detail: %{detail | jobs: jobs}}
          {:error, why} -> %{watch | detail: %{detail | error: why}}
        end

      :exits ->
        case Store.exits(store, reach, &View.wanted_exit?(state, &1)) do
          {:ok, exits} -> %{watch | detail: %{detail | exits: exits}}
          {:error, why} -> %{watch | detail: %{detail | error: why}}
        end
    end
  end

  ## What is known of a process

  # What there is to say of a process that has ended, from its record.
  @doc false
  @spec ended(Store.exit()) :: [{String.t(), String.t()}]
  def ended(%{fields: fields} = exit) do
    text = fn key ->
      case fields[key] do
        value when is_binary(value) -> value
        _ -> ""
      end
    end

    how =
      cond do
        exit.status == "unknown" -> "was gone"
        fields["crashed"] == true -> "crashed: #{exit.status}"
        exit.status == "killed" -> "was killed"
        true -> "exited #{exit.status}"
      end

    lived =
      case exit do
        %{elapsed: nil} -> ""
        %{elapsed: elapsed, whole: true} -> ", after #{Human.duration(elapsed)}"
        %{elapsed: elapsed} -> ", after more than #{Human.duration(elapsed)}"
      end

    [
      {"was", exit.name},
      {"named", if(text.("name") == exit.name, do: "", else: text.("name"))},
      {"started with", text.("path")},
      {"in", exit.app},
      {"started by", text.("parent_name") <> text.("parent")},
      {"for", text.("caller")},
      {"started",
       if(is_number(fields["started"]), do: Clock.format(fields["started"]), else: "")},
      {"ended", "#{Clock.format(exit.at)}: #{how}#{lived}"},
      {"reason", text.("reason")},
      {"where", text.("at")},
      {"reductions", if(exit.reductions, do: Human.count(exit.reductions), else: "")},
      {"peak memory", if(exit.peak_memory, do: Human.bytes(exit.peak_memory), else: "")},
      {"queue",
       if(is_number(fields["message_queue_len"]),
         do: "#{fields["message_queue_len"]} waiting",
         else: ""
       )},
      {"note",
       cond do
         is_number(fields["figures_age_seconds"]) ->
           "Its figures are those of the last sweep that saw it, " <>
             "#{Human.duration(fields["figures_age_seconds"])} before it ended."

         exit.reductions == nil ->
           "No sweep saw it: it has no figures."

         true ->
           ""
       end},
      {"note",
       if(fields["source"] == "sampled",
         do: "The VM's word of its end was not heard: it was noticed gone.",
         else: ""
       )},
      {"trace", text.("trace_id")}
    ]
    |> Enum.reject(fn {_label, value} -> value == "" end)
  end

  # Go to the moment of the picked row: when the process ended, or when
  # the job began.
  defp go(%__MODULE__{state: state, detail: detail} = watch) do
    at =
      case state.tab do
        :exits ->
          detail.exits
          |> Enum.filter(&View.wanted_exit?(state, &1))
          |> Enum.at(State.selected(state))
          |> then(&(&1 && &1.at))

        :jobs ->
          detail.jobs
          |> Enum.filter(&State.wants?(state, [&1.name, &1.app]))
          |> Enum.at(State.selected(state))
          |> then(&(&1 && &1.started))

        _ ->
          nil
      end

    cond do
      at == nil ->
        said = "An exit or a job has a moment to go to: views 3 and 4."
        %{watch | state: %{state | message: said}}

      detail.range == nil ->
        %{watch | state: %{state | message: "There is nothing stored to go to."}}

      true ->
        %{watch | state: State.go_to(state, at, detail.range)}
    end
  end

  # Open the picked row.
  defp open(%__MODULE__{state: state, detail: detail, snapshot: snapshot} = watch) do
    case state.tab do
      :groups ->
        case Enum.at(State.groups(state, snapshot), State.selected(state)) do
          nil ->
            watch

          %{name: name} ->
            %{watch | state: State.enter(state, {if(state.apps, do: :app, else: :group), name})}
        end

      :processes ->
        case Enum.at(State.processes(state, snapshot), State.selected(state)) do
          nil ->
            watch

          process ->
            # How it ended, if it has since the moment looked at; and
            # what it is doing, if it has not.
            from = state.at || snapshot.at

            known =
              case Store.record(watch.store, process.group, process.pid, from - 1) do
                %{} = exit ->
                  ended(exit)

                nil ->
                  [{"is", process.group}, {"in", process.app}] ++
                    ((watch.live && Live.describe(watch.live, process.pid)) ||
                       [
                         {"ended",
                          "Nothing says that it has, and nothing of it is known but this."}
                       ])
              end

            inspecting(watch, process.proc, known)
        end

      :exits ->
        exit =
          detail.exits
          |> Enum.filter(&View.wanted_exit?(state, &1))
          |> Enum.at(State.selected(state))

        if exit, do: inspecting(watch, exit.name <> exit.pid, ended(exit)), else: watch

      :jobs ->
        watch
    end
  end

  defp inspecting(watch, title, lines) do
    %{
      watch
      | detail: %{watch.detail | inspected: {title, lines}},
        state: %{watch.state | inspecting: true}
    }
  end

  ## The screen

  defp draw(%__MODULE__{} = watch, size) do
    {state, canvas} = View.draw(watch.state, watch.snapshot, watch.detail, size)
    {%{watch | state: state}, canvas}
  end

  defp sized(watch, {columns, _rows}),
    do: %{watch | width: max(columns - 40, 40), columns: columns}

  # The screen as the text on it, of a size.
  @doc false
  @spec screen(t(), {pos_integer(), pos_integer()}) :: {t(), [String.t()]}
  def screen(%__MODULE__{} = watch, size) do
    {watch, canvas} = watch |> sized(size) |> draw(size)
    {watch, Canvas.text(canvas)}
  end

  defp interactive(%__MODULE__{} = watch) do
    with {:ok, terminal} <- Terminal.start() do
      try do
        watch = watch |> sized(Terminal.size()) |> read_moment()
        loop(watch, terminal, System.monotonic_time(:millisecond))
      after
        Terminal.stop(terminal)
      end
    end
  end

  defp loop(%__MODULE__{state: %State{quit: true}}, _terminal, _read_at), do: :ok

  defp loop(%__MODULE__{} = watch, terminal, read_at) do
    size = Terminal.size()
    {watch, canvas} = watch |> sized(size) |> draw(size)
    terminal = Terminal.draw(terminal, canvas)
    elapsed = System.monotonic_time(:millisecond) - read_at

    wait =
      if State.live?(watch.state), do: max(watch.refresh - elapsed, 20), else: 1000

    case Terminal.keys(terminal, wait) do
      :eof ->
        :ok

      [] ->
        if State.live?(watch.state) do
          loop(read_moment(watch), terminal, System.monotonic_time(:millisecond))
        else
          # A moment in the past does not change. How long ago it was
          # does, and how far the store goes.
          {range, store} = Store.range(watch.store)
          detail = %{watch.detail | now: Clock.now(), range: range}
          loop(%{watch | store: store, detail: detail}, terminal, read_at)
        end

      keys ->
        # Every key that was waiting, before anything is read: holding an
        # arrow down goes through time without reading each moment
        # passed on the way.
        within = watch.state.within
        {watch, changed} = pressed(watch, keys)

        cond do
          changed != :moment ->
            loop(watch, terminal, read_at)

          # Into a group, or out of one, is other processes to ask for.
          State.live?(watch.state) and watch.state.within == within and
              System.monotonic_time(:millisecond) - read_at < watch.refresh ->
            # Now has been read already; only what goes with it has
            # changed.
            loop(read_detail(watch), terminal, read_at)

          true ->
            loop(read_moment(watch), terminal, System.monotonic_time(:millisecond))
        end
    end
  end

  # What keys did to what is watched, and what there is to do about it.
  @doc false
  @spec pressed(t(), [Terminal.key()]) :: {t(), State.changed()}
  def pressed(%__MODULE__{} = watch, keys) do
    Enum.reduce(keys, {watch, :nothing}, fn key, {watch, changed} ->
      {state, did} = State.key(watch.state, key, Clock.now(), watch.detail.range)
      watch = %{watch | state: state}

      case did do
        :moment ->
          {watch, :moment}

        :view ->
          {watch, if(changed == :nothing, do: :view, else: changed)}

        :go ->
          {go(watch), :moment}

        # Into a group is into another view, with another row's history
        # to read.
        :open ->
          {open(watch), :moment}

        :nothing ->
          {watch, changed}
      end
    end)
  end

  # Draw the screen once, as text: for a script, or for where there is no
  # terminal to draw on.
  defp print(%__MODULE__{} = watch, size) do
    with {:ok, size} <- size(size) do
      {_watch, lines} = watch |> sized(size) |> read_moment() |> screen(size)
      IO.puts(Enum.join(lines, "\n"))
    end
  end

  defp size({columns, rows}) when columns >= 40 and rows >= 12, do: {:ok, {columns, rows}}

  defp size(written) when is_binary(written) do
    with [columns, rows] <- String.split(written, "x"),
         {columns, ""} <- Integer.parse(columns),
         {rows, ""} <- Integer.parse(rows),
         true <- columns >= 40 and rows >= 12 do
      {:ok, {columns, rows}}
    else
      _ -> {:error, "#{inspect(written)} is not a size: expected WIDTHxHEIGHT, at least 40x12"}
    end
  end

  defp size(other),
    do: {:error, "#{inspect(other)} is not a size: expected WIDTHxHEIGHT, at least 40x12"}
end
