defmodule TimelessBeamAcct.Watch.View do
  @moduledoc """
  Drawing the screen.

  It is the screen of `timeless-acct watch`, of a node where that is of a
  host: the timeline across the top, four views of one moment under it,
  and under the first two the last ten minutes of the row that is picked.
  """

  alias TimelessBeamAcct.{Clock, Human}
  alias TimelessBeamAcct.Watch.{Canvas, Data, State, Store}

  defmodule Detail do
    @moduledoc """
    What is read for the screen besides the moment itself.
    """

    @type t :: %__MODULE__{}

    defstruct now: 0.0,
              # What is watched: the node, as it is written.
              node: "",
              # The first and last moments the store holds.
              range: nil,
              # The picked row's figure over the minutes up to the moment,
              # what it is a figure of, and of which kind.
              history: [],
              history_of: "",
              history_kind: :work,
              # The stretch the history is of: its length in seconds, and
              # the moment it runs up to.
              history_span: 600.0,
              history_until: 0.0,
              jobs: [],
              exits: [],
              # How busy the schedulers were over the stretch the timeline
              # shows, how far apart the figures are, and the stretch.
              timeline: [],
              timeline_step: 10.0,
              window: {0.0, 0.0},
              # What went wrong in it.
              incidents: [],
              # What is known of the row that was opened: a title, and
              # what there is to say under it.
              inspected: nil,
              # Seconds between the store's samples.
              step: 10.0,
              # Whether there is a store with other moments than now in it.
              stored: true,
              # What went wrong reading, if something did.
              error: nil
  end

  @dim [:dark_gray]
  @head [:cyan, :bold]
  @bad [:red]
  @warn [:yellow]
  @good [:green]

  ## Figures

  defp figure(nil, _show), do: "-"
  defp figure(value, show), do: show.(value)

  defp percent(value), do: figure(value, &Human.fixed(&1, 1))
  defp bytes(value), do: figure(value, &Human.bytes(max(&1, 0)))
  defp count(value), do: figure(value, &Human.count(round(&1)))
  defp rate(value), do: figure(value, &Human.fixed(&1, 1))

  # A figure that is worth a colour when it is high.
  defp heat(value, _warm, hot) when is_number(value) and value >= hot, do: @bad
  defp heat(value, warm, _hot) when is_number(value) and value >= warm, do: @warn
  defp heat(_value, _warm, _hot), do: []

  defp clock(at), do: at |> Clock.format() |> String.slice(11..-1//1)

  ## The screen

  @doc """
  Draw the screen, on a canvas of a size. The state comes back with its
  picked row kept on a row there is.
  """
  @spec draw(State.t(), Data.t(), Detail.t(), {pos_integer(), pos_integer()}) ::
          {State.t(), Canvas.t()}
  def draw(%State{} = state, %Data{} = snapshot, %Detail{} = detail, {width, height}) do
    canvas = Canvas.new(width, height)
    body = {0, 7, width, max(height - 8, 0)}

    canvas =
      canvas
      |> header({0, 0, width, 6}, state, snapshot, detail)
      |> tabs(6, state)

    {state, canvas} =
      case state.tab do
        tab when tab in [:groups, :processes] ->
          {x, y, width, rows} = body
          table = {x, y, width, max(rows - 6, 0)}

          {state, canvas} =
            if tab == :groups,
              do: groups(canvas, table, state, snapshot),
              else: processes(canvas, table, state, snapshot)

          {state, history(canvas, {x, y + max(rows - 6, 0), width, min(rows, 6)}, detail)}

        :jobs ->
          jobs(canvas, body, state, detail)

        :exits ->
          exits(canvas, body, state, detail)
      end

    canvas = keys(canvas, height - 1, state, detail)
    canvas = if state.help, do: help(canvas), else: canvas

    canvas =
      case {state.inspecting, detail.inspected} do
        {true, {title, lines}} -> inspected(canvas, title, lines)
        _ -> canvas
      end

    {state, canvas}
  end

  defp header(canvas, area, state, snapshot, detail) do
    {from, to} = detail.window

    right =
      case state.at do
        nil ->
          at = if Data.empty?(snapshot), do: detail.now, else: snapshot.at
          [{" ● LIVE ", [:bold | @good]}, {Clock.format(at), @dim}, " "]

        at ->
          [
            {" ◀ ", @warn},
            {Clock.format(at), [:bold | @warn]},
            {"  #{Store.ago(detail.now, at)} ", @warn}
          ]
      end

    # A stretch within a day is told by the time; a longer one needs the
    # day as well.
    tell = fn at ->
      text = Clock.format(at)
      if to - from > 86_400, do: String.slice(text, 5, 11), else: String.slice(text, 11, 5)
    end

    below =
      if to > from do
        highest = detail.timeline |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0.0 end)

        [
          bottom: [{" #{tell.(from)} ", @dim}],
          bottom_center: [
            {" schedulers over #{Human.duration(to - from)}, up to #{Human.fixed(highest, 1)}% ",
             @dim}
          ],
          bottom_right: [{" #{tell.(to)} ", @dim}]
        ]
      else
        []
      end

    {canvas, {x, y, width, _rows}} =
      Canvas.box(
        canvas,
        area,
        [title: [{" timeless-beam-acct ", @head}, {detail.node <> " ", @dim}], right: right] ++
          below
      )

    canvas =
      if to > from do
        data = columns(detail.timeline, to, to - from, width, detail.timeline_step)
        cursor = state.at || to

        marked =
          width
          |> marks(from, to, cursor, detail.incidents)
          |> Enum.map(fn
            :nothing -> " "
            :killed -> {"·", @warn}
            :fault -> {"!", [:bold | @bad]}
            :here -> {"▲", @head}
            :here_killed -> {"▲", @warn}
            :here_fault -> {"▲", @bad}
          end)

        # Drawn to the highest in the stretch, which the frame says: a
        # node is seldom near all of its schedulers, and drawn to a
        # hundred its busiest hour would be a flat line.
        canvas
        |> Canvas.sparkline({x, y + 2, width, 1}, data, [:blue])
        |> Canvas.spans(x, y + 3, marked, width)
        |> elem(0)
      else
        canvas
      end

    if Data.empty?(snapshot) do
      why =
        case {state.at, detail.range} do
          {_, nil} when detail.stored -> "The store holds nothing yet."
          {_, nil} -> "The collector has read nothing yet."
          {at, {first, _}} when is_number(at) and at < first -> "Before the store began."
          _ -> "Nothing was recorded at this moment: the collector was not running."
        end

      Canvas.put(canvas, x, y, why, @warn, width)
    else
      vm = snapshot.vm
      label = &{&1, @dim}

      # Each line is what it has room for: a part that would be cut is
      # left out, and the parts that matter most are first.
      first = [
        [label.("run queue "), {count(vm[:run_queue]), heat(vm[:run_queue], 10, 100)}],
        [
          label.("   schedulers "),
          {percent(vm[:schedulers]) <> "%", heat(vm[:schedulers], 60.0, 85.0)},
          label.(" (cpu "),
          percent(vm[:cpu]) <> "%",
          label.(")")
        ],
        [label.("   mem "), bytes(vm[:memory])],
        [
          label.(" (processes "),
          bytes(vm[:memory_processes]),
          label.(" binary "),
          bytes(vm[:memory_binary]),
          label.(" ets "),
          bytes(vm[:memory_ets]),
          label.(")")
        ]
      ]

      second = [
        [label.("work "), "#{count(vm[:reductions])} reds/s"],
        [
          label.("   processes "),
          {count(vm[:processes]), heat(vm[:processes_pct], 80.0, 92.0)},
          label.(" (+"),
          rate(vm[:spawns]),
          label.(" -"),
          rate(vm[:exits]),
          label.("/s)")
        ],
        [label.("   gc "), "#{count(vm[:gcs])}/s"],
        [label.("   io "), "↓#{bytes(vm[:io_in])}/s ↑#{bytes(vm[:io_out])}/s"],
        [
          label.("   atoms "),
          {percent(vm[:atoms_pct]) <> "%", heat(vm[:atoms_pct], 80.0, 92.0)}
        ],
        if(vm[:uptime], do: [label.("   up "), Human.duration(vm[:uptime])], else: [])
      ]

      canvas
      |> Canvas.spans(x, y, fitting(first, width), width)
      |> elem(0)
      |> Canvas.spans(x, y + 1, fitting(second, width), width)
      |> elem(0)
    end
  end

  # The parts of a line that there is room for, in order.
  defp fitting(parts, width) do
    {kept, _used} =
      Enum.reduce_while(parts, {[], 0}, fn part, {kept, used} ->
        used = used + Canvas.length(part)
        if used <= width, do: {:cont, {kept ++ part, used}}, else: {:halt, {kept, used}}
      end)

    kept
  end

  @typedoc "What is under one column of the timeline."
  @type mark :: :nothing | :killed | :fault | :here | :here_killed | :here_fault

  @doc """
  What to put under each column of the timeline: what went wrong in the
  time it stands for, and where the moment looked at is.
  """
  @spec marks(non_neg_integer(), number(), number(), number(), [Store.incident()]) :: [mark()]
  def marks(width, from, to, _cursor, _incidents) when width <= 0 or to <= from,
    do: List.duplicate(:nothing, max(width, 0))

  def marks(width, from, to, cursor, incidents) do
    column = fn at ->
      position = (at - from) / (to - from) * width
      if position >= 0 and at <= to, do: min(trunc(position), width - 1)
    end

    marked =
      Enum.reduce(incidents, %{}, fn incident, marked ->
        case column.(incident.at) do
          nil -> marked
          # A fault is not hidden by a kill in the same column.
          at when incident.error -> Map.put(marked, at, :fault)
          at -> Map.put_new(marked, at, :killed)
        end
      end)

    marked =
      case column.(cursor) do
        nil ->
          marked

        at ->
          Map.put(
            marked,
            at,
            case marked[at] do
              :fault -> :here_fault
              :killed -> :here_killed
              _ -> :here
            end
          )
      end

    for at <- 0..(width - 1), do: Map.get(marked, at, :nothing)
  end

  defp tabs(canvas, y, state) do
    titles =
      State.tabs()
      |> Enum.with_index(1)
      |> Enum.map(fn {tab, index} ->
        text = " #{index} #{State.title(tab)} "
        if tab == state.tab, do: {text, [:reversed | @head]}, else: {text, @dim}
      end)

    sorted =
      if state.tab in [:groups, :processes],
        do: [{"   by ", @dim}, State.sort_title(state.sort)],
        else: []

    apps =
      if state.tab == :groups and state.apps, do: [{"   applications", @dim}], else: []

    within =
      case {state.tab, state.within} do
        {:processes, {_kind, name}} -> [{"   in ", @dim}, {name, @head}]
        _ -> []
      end

    only =
      if state.typing or state.filter != "",
        do: [{"   only ", @dim}, {state.filter <> if(state.typing, do: "▏", else: ""), @warn}],
        else: []

    canvas |> Canvas.spans(0, y, titles ++ sorted ++ apps ++ within ++ only) |> elem(0)
  end

  defp right(text, style \\ []), do: {:right, text, style}

  defp groups(canvas, area, state, snapshot) do
    rows = State.groups(state, snapshot)
    state = State.clamp(state, length(rows))

    cells =
      for group <- rows do
        [
          {group.name, []},
          right(percent(group.work), heat(group.work, 25.0, 50.0)),
          right(bytes(group.memory)),
          right(count(group.processes)),
          right(count(group.queue), heat(group.queue, 1000, 10_000)),
          right(count(group.reductions)),
          right(rate(group.exits), if((group.failures || 0) > 0, do: @warn, else: []))
        ]
      end

    canvas =
      Canvas.table(
        canvas,
        area,
        [if(state.apps, do: "APP", else: "GROUP"), "WORK%", "MEMORY", "PROCS", "MSGQ"] ++
          ["REDS/s", "ENDED/s"],
        [min: 24, length: 7, length: 10, length: 6, length: 7, length: 9, length: 8],
        cells,
        picked: State.selected(state)
      )

    {state, canvas}
  end

  defp processes(canvas, area, state, snapshot) do
    rows = State.processes(state, snapshot)
    state = State.clamp(state, length(rows))

    cells =
      for process <- rows do
        [
          {process.name, []},
          right(process.pid, @dim),
          {process.app, []},
          right(percent(process.work), heat(process.work, 25.0, 50.0)),
          right(bytes(process.memory)),
          right(count(process.queue), heat(process.queue, 1000, 10_000)),
          right(count(process.reductions))
        ]
      end

    canvas =
      Canvas.table(
        canvas,
        area,
        ["PROCESS", "PID", "APP", "WORK%", "MEMORY", "MSGQ", "REDS"],
        [min: 18, length: 14, length: 12, length: 7, length: 10, length: 7, length: 9],
        cells,
        picked: State.selected(state)
      )

    {state, canvas}
  end

  @doc """
  The values of a history, one to a column, the latest at the right.

  A sample stands until the next one is due, `step` seconds on, so a
  screen wider than the history is long has no holes in it. A column in
  which nothing was recorded, and nothing was standing, is empty: the
  collector was not running, or what is drawn was not there.
  """
  @spec columns([{number(), number()}], number(), number(), integer(), number()) :: [number()]
  def columns(_history, _until, span, width, _step) when width <= 0 or span <= 0, do: []

  def columns(history, until, span, width, step) do
    from = until - span
    each = span / width

    {columns, _left, _standing} =
      Enum.reduce(0..(width - 1), {[], history, nil}, fn column, {columns, samples, standing} ->
        {start, stop} = {from + each * column, from + each * (column + 1)}
        last = column + 1 == width

        # The last column takes the moment the stretch runs up to.
        {taken, samples} =
          Enum.split_while(samples, fn {at, _} -> at < stop or (last and at <= until) end)

        highest =
          taken
          |> Enum.filter(fn {at, _} -> at >= start end)
          |> Enum.map(&elem(&1, 1))
          |> Enum.max(fn -> nil end)

        standing = List.last(taken) || standing

        value =
          case {highest, standing} do
            {nil, {at, value}} when start - at < step * 1.5 -> value
            {nil, _} -> 0.0
            {highest, _} -> highest
          end

        {[max(value, 0.0) | columns], samples, standing}
      end)

    Enum.reverse(columns)
  end

  defp history(canvas, {_x, _y, _width, height}, _detail) when height < 3, do: canvas

  defp history(canvas, area, detail) do
    title =
      if detail.history_of == "",
        do: " nothing selected ",
        else: " #{detail.history_of}, the #{Human.duration(detail.history_span)} before "

    peak = detail.history |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> nil end)

    said =
      case {peak, detail.history_kind} do
        {nil, _} -> []
        {peak, :memory} -> [{" peak #{Human.bytes(peak)} ", @dim}]
        {peak, :queue} -> [{" peak #{Human.count(round(peak))} waiting ", @dim}]
        {peak, _} -> [{" peak #{Human.fixed(peak, 1)}% ", @dim}]
      end

    {canvas, {x, y, width, _rows} = inner} =
      Canvas.box(canvas, area, title: [{title, @dim}], right: said)

    cond do
      detail.history != [] ->
        data =
          columns(detail.history, detail.history_until, detail.history_span, width, detail.step)

        Canvas.sparkline(canvas, inner, data, [:cyan])

      detail.history_of == "" ->
        canvas

      not detail.stored ->
        Canvas.put(
          canvas,
          x,
          y,
          "The collector writes to nothing that can be asked.",
          @dim,
          width
        )

      true ->
        Canvas.put(
          canvas,
          x,
          y,
          "Not in the store: it has no series of its own, or none yet.",
          @dim,
          width
        )
    end
  end

  defp jobs(canvas, {x, y, width, height}, state, detail) do
    jobs = Enum.filter(detail.jobs, &State.wants?(state, [&1.name, &1.app]))
    state = State.clamp(state, length(jobs))
    list = div(height * 4, 10)

    cells =
      for job <- jobs do
        [
          {clock(job.started), []},
          right(Integer.to_string(job.processes)),
          if(job.failed > 0,
            do: right(Integer.to_string(job.failed), @bad),
            else: right("-", @dim)
          ),
          # So far: it has not ended.
          if(job.running,
            do: right(Human.duration(job.duration) <> "…", @good),
            else: right(Human.duration(job.duration))
          ),
          right(count(job.reductions)),
          {job.name, []},
          {job.app, @dim}
        ]
      end

    canvas =
      Canvas.table(
        canvas,
        {x, y, width, list},
        ["STARTED", "PROCS", "FAILED", "TOOK", "REDS", "JOB", "APP"],
        [length: 8, length: 5, length: 6, length: 9, length: 8, min: 30, min: 16],
        cells,
        picked: State.selected(state)
      )

    {canvas, {inner_x, inner_y, inner_width, inner_height}} =
      Canvas.box(canvas, {x, y + list, width, height - list}, title: [{" what it was ", @dim}])

    lines =
      case Enum.at(jobs, State.selected(state)) do
        nil ->
          [{"No jobs in the quarter of an hour before. A job is more than one process.", @dim}]

        job ->
          for line <- job.tree do
            if String.contains?(line, "  ["), do: {line, @bad}, else: {line, []}
          end
      end

    canvas =
      lines
      |> Enum.take(max(inner_height, 0))
      |> Enum.with_index(inner_y)
      |> Enum.reduce(canvas, fn {{line, style}, row}, canvas ->
        Canvas.put(canvas, inner_x, row, line, style, inner_width)
      end)

    {state, canvas}
  end

  defp exits(canvas, area, state, detail) do
    exits = Enum.filter(detail.exits, &wanted_exit?(state, &1))
    state = State.clamp(state, length(exits))

    cells =
      for exit <- exits do
        style =
          case exit.level do
            "error" -> @bad
            "warning" -> @warn
            "notice" -> [:magenta]
            _ -> []
          end

        took =
          case exit do
            %{elapsed: nil} -> "-"
            %{elapsed: elapsed, whole: true} -> Human.duration(elapsed)
            %{elapsed: elapsed} -> ">" <> Human.duration(elapsed)
          end

        [
          {clock(exit.at), []},
          right(exit.pid, @dim),
          {exit.status, style},
          right(took),
          right(count(exit.reductions)),
          right(bytes(exit.peak_memory)),
          {exit.process, []}
        ]
      end

    canvas =
      Canvas.table(
        canvas,
        area,
        ["ENDED", "PID", "STATUS", "TOOK", "REDS", "PEAK MEM", "PROCESS"],
        [length: 8, length: 14, length: 14, length: 8, length: 8, length: 10, min: 30],
        cells,
        picked: State.selected(state)
      )

    {state, canvas}
  end

  @doc "Whether an exit is wanted: by what it was, where, or how it ended."
  @spec wanted_exit?(State.t(), Store.exit()) :: boolean()
  def wanted_exit?(state, exit),
    do: State.wants?(state, [exit.process, exit.app, exit.status, exit.pid])

  # A step in time, as a key is said to take it: `10s`, `1s`, `2m`.
  defp pace(step) do
    seconds = max(round(step), 1)
    if rem(seconds, 60) == 0, do: "#{div(seconds, 60)}m", else: "#{seconds}s"
  end

  defp keys(canvas, y, state, detail) do
    cond do
      detail.error ->
        Canvas.put(canvas, 0, y, " " <> detail.error, @bad)

      state.message ->
        Canvas.put(canvas, 0, y, " " <> state.message, @warn)

      state.going ->
        canvas
        |> Canvas.spans(0, y, [
          {" go to ", @head},
          {state.going <> "▏", @warn},
          {"    now   -15m   14:30   2026-09-29 14:30   enter to go, esc to stay", @dim}
        ])
        |> elem(0)

      true ->
        step = pace(state.step)

        keys =
          cond do
            state.typing ->
              [{"enter", "keep"}, {"esc", "clear"}]

            state.within ->
              [{"esc", "back to groups"}, {"enter", "open"}, {"←→", step}, {",.", "1m"}] ++
                [{"<>", "10m"}, {"t", "go to"}, {"l", "live"}, {"s", "sort"}, {"/", "only"}] ++
                [{"?", "help"}]

            true ->
              [{"←→", step}, {",.", "1m"}, {"<>", "10m"}, {"[]", "1h"}, {"t", "go to"}] ++
                [{"l", "live"}, {"-+", "zoom"}, {"tab", "view"}, {"enter", "open"}] ++
                [{"m", "its moment"}, {"s", "sort"}, {"/", "only"}, {"?", "help"}, {"q", "quit"}]
          end

        spans = Enum.flat_map(keys, fn {key, what} -> [{" #{key} ", @head}, {what, @dim}] end)
        canvas |> Canvas.spans(0, y, spans) |> elem(0)
    end
  end

  @help [
    "Time",
    "  ← →        one reading back, forward",
    "  , .        a minute          (or shift ← →)",
    "  < >        ten minutes",
    "  [ ]        an hour",
    "  { }        a day",
    "  home       the first moment in the store",
    "  t          go to a moment: -15m, 14:30, 2026-09-29 14:30",
    "  l, end     now",
    "  - +        a longer stretch of the timeline, a shorter",
    "  m          go to the moment of the selected exit or job",
    "",
    "Under the timeline:  ▲ the moment looked at",
    "                     ! a process raised, uncaught   · one was killed",
    "",
    "Views",
    "  tab, 1-4   groups, processes, jobs, exits",
    "  ↑ ↓ j k    select a row       pgup pgdn  ten rows",
    "  enter      open it: a group's processes, or what a process was",
    "  esc        back out of a group",
    "  g G        the first row, the last",
    "  s          sort by work, memory, queue, name",
    "  a          applications, in place of groups",
    "  /          show only what matches",
    "",
    "Now is what the collector in the node last read. Every other moment",
    "is read from the store, which the collector adds to at every reading.",
    "",
    "  q          quit"
  ]

  defp popup(canvas, width, height) do
    width = min(width, canvas.width)
    height = min(height, canvas.height)
    area = {div(canvas.width - width, 2), div(canvas.height - height, 2), width, height}
    {Canvas.clear(canvas, area), area}
  end

  defp help(canvas) do
    {canvas, area} = popup(canvas, 72, length(@help) + 2)
    {canvas, {x, y, width, height}} = Canvas.box(canvas, area, title: [{" keys ", @head}])

    @help
    |> Enum.take(max(height, 0))
    |> Enum.with_index(y)
    |> Enum.reduce(canvas, fn {line, row}, canvas ->
      Canvas.put(canvas, x, row, line, [], width)
    end)
  end

  @doc """
  A text in lines of at most `width` characters, broken between words
  where there is a between, and within one where there is not.
  """
  @spec fold(String.t(), pos_integer()) :: [String.t()]
  def fold(text, width) do
    {lines, line} =
      text
      |> String.split(" ")
      |> Enum.reduce({[], ""}, fn word, {lines, line} ->
        {lines, line} =
          if line != "" and String.length(line) + 1 + String.length(word) > width,
            do: {[line | lines], ""},
            else: {lines, line}

        # A word longer than a line: a path, or a term with no spaces in
        # it.
        {lines, line, word} = broken(lines, line, word, width)
        {lines, if(line == "", do: word, else: line <> " " <> word)}
      end)

    Enum.reverse(if line != "" or lines == [], do: [line | lines], else: lines)
  end

  defp broken(lines, line, word, width) do
    if String.length(word) > width do
      lines = if line == "", do: lines, else: [line | lines]
      {part, rest} = String.split_at(word, width)
      broken([part | lines], "", rest, width)
    else
      {lines, line, word}
    end
  end

  # What is known of one process, over the rest of the screen.
  defp inspected(canvas, title, lines) do
    width = (canvas.width - 8) |> max(min(40, canvas.width)) |> min(110)
    inner = max(width - 18, 1)

    # What a process was is as long as it is, and is folded to fit.
    text =
      for {label, value} <- lines,
          {part, index} <- value |> fold(inner) |> Enum.with_index() do
        [{" " <> String.pad_trailing(if(index == 0, do: label, else: ""), 14) <> " ", @dim}, part]
      end

    {canvas, area} = popup(canvas, width, length(text) + 2)

    {canvas, {x, y, inner_width, height}} =
      Canvas.box(canvas, area, title: [{" #{title} ", @head}], right: [{" any key ", @dim}])

    text
    |> Enum.take(max(height, 0))
    |> Enum.with_index(y)
    |> Enum.reduce(canvas, fn {spans, row}, canvas ->
      canvas |> Canvas.spans(x, row, spans, inner_width) |> elem(0)
    end)
  end

  @doc """
  What the picked row's history is a history of: the metric, the label
  that names the row, the row, what to call it, and of which kind it is.
  """
  @spec history_of(State.t(), Data.t()) ::
          {String.t(), String.t(), String.t(), String.t(), :work | :memory | :queue} | nil
  def history_of(%State{} = state, %Data{} = snapshot) do
    {kind, suffix, what} =
      case state.sort do
        :memory -> {:memory, "memory_bytes", "memory"}
        :queue -> {:queue, "message_queue_len", "queue"}
        _ -> {:work, "work_pct", "work"}
      end

    case state.tab do
      :groups ->
        {prefix, key} = if state.apps, do: {"beam_app", "app"}, else: {"beam_group", "group"}

        with %{name: name} <- Enum.at(State.groups(state, snapshot), State.selected(state)) do
          {"#{prefix}_#{suffix}", key, name, "#{name} #{what}", kind}
        end

      :processes ->
        with %{proc: proc} <- Enum.at(State.processes(state, snapshot), State.selected(state)) do
          {"beam_proc_#{suffix}", "proc", proc, "#{proc} #{what}", kind}
        end

      _ ->
        nil
    end
  end
end
