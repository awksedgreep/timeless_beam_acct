if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
  defmodule TimelessBeamAcct.Dashboard.Opened do
    @moduledoc """
    A recording, opened on the page: `watch`'s screen as HTML.

    What is shown is read as `watch` reads it, by `TimelessBeamAcct.Watch`,
    and what a key does is what it does there (`Watch.State.key/4`): the
    two cannot come to differ. Only the drawing is the page's.
    """

    use Phoenix.Component

    alias TimelessBeamAcct.{Clock, Human, Watch}
    alias TimelessBeamAcct.Watch.{Data, State, Store, View}

    # Columns of the timeline, and of a row's history.
    @columns 120

    @doc "How many columns the timeline is drawn in."
    def columns, do: @columns

    @doc """
    A recording, opened: read as `watch` reads one, of the planes the page
    is configured with, at its end.
    """
    @spec open(String.t(), keyword()) :: {:ok, Watch.t()} | {:error, String.t()}
    def open(id, planes) do
      with {:ok, watch} <- Watch.new(planes ++ [recording: id]) do
        # As wide as a terminal of so many columns, for the trees of jobs.
        {:ok, Watch.read_moment(%{watch | columns: @columns + 2, width: 100})}
      end
    end

    @doc """
    A key pressed on the page, as `watch` has it; `nil` if it is not one
    of `watch`'s.
    """
    @spec key(String.t(), boolean()) :: TimelessBeamAcct.Watch.Terminal.key() | nil
    def key("ArrowLeft", true), do: {:shift, :left}
    def key("ArrowRight", true), do: {:shift, :right}
    def key("ArrowLeft", _), do: :left
    def key("ArrowRight", _), do: :right
    def key("ArrowUp", _), do: :up
    def key("ArrowDown", _), do: :down
    def key("Enter", _), do: :enter
    def key("Escape", _), do: :esc
    def key("Backspace", _), do: :backspace
    def key("Home", _), do: :home
    def key("End", _), do: :end
    def key("PageUp", _), do: :page_up
    def key("PageDown", _), do: :page_down
    def key(<<_::utf8>> = char, _), do: {:char, char}
    def key(_other, _), do: nil

    @doc "A key, done to what is watched: read again if there is reading to do."
    @spec pressed(Watch.t(), TimelessBeamAcct.Watch.Terminal.key()) :: Watch.t()
    def pressed(watch, key) do
      case Watch.pressed(watch, [key]) do
        {watch, :moment} -> Watch.read_moment(watch)
        {watch, _changed} -> watch
      end
    end

    @doc "Go to the moment a column of the timeline stands for."
    @spec go_to_column(Watch.t(), non_neg_integer()) :: Watch.t()
    def go_to_column(%{detail: %{window: {from, to}}} = watch, column) when to > from do
      at = from + (to - from) * (column + 0.5) / @columns
      Watch.read_moment(%{watch | state: State.go_to(watch.state, at, watch.detail.range)})
    end

    def go_to_column(watch, _column), do: watch

    # The three views a page has beside watch's four.
    @extras %{"5" => :node, "6" => :remarks, "7" => :collector}

    @doc """
    Which of the page's own views a number is, beside `watch`'s four:
    `5` the node, `6` what the VM remarked on, `7` the collector.
    """
    @spec extra(String.t()) :: :node | :remarks | :collector | nil
    def extra(n), do: @extras[n]

    # What is drawn of the node, and how each is said.
    @node [
      {"schedulers", "beam_vm_scheduler_util_pct", [scheduler: "all"], :pct},
      {"cpu", "beam_vm_cpu_pct", [], :pct},
      {"run queue", "beam_vm_run_queue", [], :count},
      {"work, reds/s", "beam_vm_reductions_per_sec", [], :count},
      {"processes", "beam_vm_processes", [], :count},
      {"started /s", "beam_vm_spawns_per_sec", [], :rate},
      {"ended /s", "beam_vm_exits_per_sec", [], :rate},
      {"memory", "beam_vm_mem_total_bytes", [], :bytes},
      {"processes' memory", "beam_vm_mem_processes_bytes", [], :bytes},
      {"binaries", "beam_vm_mem_binary_bytes", [], :bytes},
      {"tables", "beam_vm_mem_ets_bytes", [], :bytes},
      {"garbage collections /s", "beam_vm_gcs_per_sec", [], :rate}
    ]

    @doc """
    What one of the page's own views shows, as of the moment looked at.
    """
    @spec read_extra(Watch.t(), :node | :remarks | :collector | nil) :: term()
    def read_extra(_watch, nil), do: nil

    def read_extra(%Watch{detail: %{window: {from, to}}} = watch, :node) do
      for {label, metric, labels, kind} <- @node do
        {points, step} = Store.trend(watch.store, metric, labels, from, to)
        %{label: label, kind: kind, points: points, step: step, from: from, to: to}
      end
    end

    def read_extra(%Watch{} = watch, :remarks) do
      until = watch.state.at || watch.snapshot.at
      reach = %{until: until, span: State.window(watch.state), limit: 200}

      case Store.remarks(watch.store, reach, &State.wants?(watch.state, [&1.process, &1.status])) do
        {:ok, remarks} -> remarks
        {:error, why} -> {:error, why}
      end
    end

    def read_extra(%Watch{} = watch, :collector) do
      at = watch.state.at || watch.snapshot.at

      case Store.at(watch.store, at, watch.within, [:collector]) do
        {:ok, series} -> Data.collector(series)
        {:error, why} -> {:error, why}
      end
    end

    @doc "A view of the four, by its number."
    @spec tab(Watch.t(), String.t()) :: Watch.t()
    def tab(watch, n) when n in ["1", "2", "3", "4"], do: pressed(watch, {:char, n})
    def tab(watch, _n), do: watch

    ## Drawing

    attr(:watch, :map, required: true)
    attr(:back, :string, required: true)
    attr(:extra, :atom, default: nil)
    attr(:extra_data, :any, default: nil)

    @doc "The opened recording."
    def recording(assigns) do
      watch = assigns.watch
      {state, snapshot, detail} = {watch.state, watch.snapshot, watch.detail}

      assigns =
        assign(assigns,
          state: state,
          snapshot: snapshot,
          detail: detail,
          vm: snapshot.vm,
          empty: Data.empty?(snapshot)
        )

      ~H"""
      <div class="tba tba-opened" phx-window-keydown="key">
        <style>
          .tba-opened .tba-head { display: flex; justify-content: space-between; align-items: baseline; }
          .tba-opened .tba-live { color: #0a7; font-weight: bold; }
          .tba-opened .tba-past { color: #b80; font-weight: bold; }
          .tba-opened svg.tba-line { width: 100%; height: 3rem; display: block; }
          .tba-opened svg.tba-history { width: 100%; height: 3.5rem; display: block; }
          .tba-opened .tba-ends { display: flex; justify-content: space-between; font-size: 0.8rem; color: #888; }
          .tba-opened .tba-tabs a { margin-right: 1rem; cursor: pointer; }
          .tba-opened .tba-tabs a.tba-on { font-weight: bold; text-decoration: underline; }
          .tba-opened tr.tba-picked { background: rgba(0, 128, 255, 0.12); }
          .tba-opened .tba-figures span { margin-right: 1.25rem; }
          .tba-opened .tba-keys { font-size: 0.8rem; color: #888; margin-top: 0.75rem; }
          .tba-opened .tba-bad { color: #c33; }
          .tba-opened .tba-warn { color: #b80; }
          .tba-opened .tba-inspected { border: 1px solid rgba(0,0,0,0.15); padding: 0.75rem 1rem; margin: 0.75rem 0; }
          .tba-opened .tba-inspected td:first-child { color: #888; padding-right: 1rem; vertical-align: top; }
          .tba-opened pre { margin: 0; }
        </style>

        <div class="tba-head">
          <div>
            <a href={@back}>Recordings</a> ›
            <strong>{@detail.node}</strong>
          </div>
          <div>
            <span :if={State.live?(@state)} class="tba-live">● LIVE {Clock.format(@snapshot.at)}</span>
            <span :if={!State.live?(@state)} class="tba-past">
              ◀ {Clock.format(@state.at)} &nbsp; {Store.ago(@detail.now, @state.at)}
            </span>
          </div>
        </div>

        <.timeline state={@state} detail={@detail} />

        <div :if={@empty} class="tba-warn">Nothing was recorded at this moment.</div>
        <div :if={!@empty} class="tba-figures">
          <span>run queue {figure(@vm[:run_queue], &count/1)}</span>
          <span>schedulers {figure(@vm[:schedulers], &pct/1)}</span>
          <span>cpu {figure(@vm[:cpu], &pct/1)}</span>
          <span>mem {figure(@vm[:memory], &Human.bytes/1)}</span>
          <span>work {figure(@vm[:reductions], &count/1)} reds/s</span>
          <span>processes {figure(@vm[:processes], &count/1)}
            (+{figure(@vm[:spawns], &rate/1)} −{figure(@vm[:exits], &rate/1)}/s)</span>
        </div>

        <div class="tba-tabs">
          <a :for={{tab, n} <- Enum.with_index(State.tabs(), 1)}
             phx-click="tab" phx-value-tab={n} class={if tab == @state.tab and !@extra, do: "tba-on"}>
            {n} {State.title(tab)}
          </a>
          <a :for={{extra, title, n} <- [{:node, "Node", 5}, {:remarks, "Remarks", 6}, {:collector, "Collector", 7}]}
             phx-click="tab" phx-value-tab={n} class={if extra == @extra, do: "tba-on"}>
            {n} {title}
          </a>
          <span :if={@state.tab in [:groups, :processes]}>by {State.sort_title(@state.sort)}</span>
          <span :if={@state.within}>&nbsp; in <strong>{elem(@state.within, 1)}</strong></span>
          <span :if={@state.typing or @state.filter != ""}>&nbsp; only <strong>{@state.filter}{if @state.typing, do: "▏"}</strong></span>
        </div>

        <.inspected :if={@state.inspecting and @detail.inspected} inspected={@detail.inspected} />

        <.view :if={!@extra} state={@state} snapshot={@snapshot} detail={@detail} />
        <.extra_view :if={@extra} extra={@extra} data={@extra_data} />

        <div :if={@state.going} class="tba-warn">go to {@state.going}▏ &nbsp; now, -15m, 14:30 · enter to go, esc to stay</div>
        <div :if={@detail.error} class="tba-bad">{@detail.error}</div>
        <div :if={@state.message} class="tba-warn">{@state.message}</div>
        <div class="tba-keys">
          ← → a reading · , . a minute · &lt; &gt; ten · [ ] an hour · t go to · l live · − + zoom ·
          1–4 view · 5 node · 6 remarks · 7 collector · ↑ ↓ row · enter open · m its moment · s sort · a applications · / only ·
          or click the timeline
        </div>
      </div>
      """
    end

    attr(:state, :map, required: true)
    attr(:detail, :map, required: true)

    defp timeline(assigns) do
      {from, to} = assigns.detail.window

      {bars, marks} =
        if to > from do
          {View.columns(
             assigns.detail.timeline,
             to,
             to - from,
             @columns,
             assigns.detail.timeline_step
           ), View.marks(@columns, from, to, assigns.state.at || to, assigns.detail.incidents)}
        else
          {[], []}
        end

      highest = Enum.max([0.0 | bars])

      assigns =
        assign(assigns,
          bars: Enum.with_index(bars),
          marks: Enum.with_index(marks),
          highest: highest,
          from: from,
          to: to
        )

      ~H"""
      <svg class="tba-line" viewBox={"0 0 #{columns()} 30"} preserveAspectRatio="none">
        <rect :for={{value, column} <- @bars} x={column} width="0.9"
              y={20 - bar(value, @highest, 20)} height={bar(value, @highest, 20)} fill="#3a7bd5" />
        <g :for={{mark, column} <- @marks}>
          <rect :if={mark in [:fault, :here_fault]} x={column} y="22" width="0.9" height="3" fill="#c33" />
          <rect :if={mark in [:killed, :here_killed]} x={column + 0.3} y="23" width="0.3" height="1.5" fill="#b80" />
          <polygon :if={mark in [:here, :here_fault, :here_killed]}
                   points={"#{column},30 #{column + 0.45},26 #{column + 0.9},30"} fill="#0aa" />
        </g>
        <rect :for={column <- 0..(columns() - 1)} x={column} y="0" width="1" height="30"
              fill="transparent" phx-click="goto" phx-value-column={column} style="cursor: pointer" />
      </svg>
      <div :if={@to > @from} class="tba-ends">
        <span>{tell(@from, @to, @from)}</span>
        <span>schedulers over {Human.duration(@to - @from)}, up to {Human.fixed(@highest, 1)}%
          · <span class="tba-bad">▮</span> raised · <span class="tba-warn">·</span> killed</span>
        <span>{tell(@from, @to, @to)}</span>
      </div>
      """
    end

    attr(:inspected, :any, required: true)

    defp inspected(assigns) do
      ~H"""
      <div class="tba-inspected">
        <strong>{elem(@inspected, 0)}</strong> <small>(any key)</small>
        <table>
          <tr :for={{label, value} <- elem(@inspected, 1)}><td>{label}</td><td>{value}</td></tr>
        </table>
      </div>
      """
    end

    attr(:state, :map, required: true)
    attr(:snapshot, :map, required: true)
    attr(:detail, :map, required: true)

    defp view(%{state: %{tab: :groups}} = assigns) do
      rows = State.groups(assigns.state, assigns.snapshot)

      assigns =
        assign(assigns, rows: Enum.with_index(rows), picked: State.selected(assigns.state))

      ~H"""
      <table>
        <thead><tr><th>{if @state.apps, do: "APP", else: "GROUP"}</th><th>WORK%</th><th>MEMORY</th><th>PROCS</th><th>MSGQ</th><th>REDS/s</th><th>ENDED/s</th></tr></thead>
        <tbody>
          <tr :for={{g, i} <- @rows} class={if i == @picked, do: "tba-picked"}>
            <td>{g.name}</td><td>{figure(g.work, &pct/1)}</td><td>{figure(g.memory, &Human.bytes/1)}</td>
            <td>{figure(g.processes, &count/1)}</td><td>{figure(g.queue, &count/1)}</td>
            <td>{figure(g.reductions, &count/1)}</td><td>{figure(g.exits, &rate/1)}</td>
          </tr>
        </tbody>
      </table>
      <.history detail={@detail} />
      """
    end

    defp view(%{state: %{tab: :processes}} = assigns) do
      rows = State.processes(assigns.state, assigns.snapshot)

      assigns =
        assign(assigns, rows: Enum.with_index(rows), picked: State.selected(assigns.state))

      ~H"""
      <table>
        <thead><tr><th>PROCESS</th><th>PID</th><th>APP</th><th>WORK%</th><th>MEMORY</th><th>MSGQ</th><th>REDS</th></tr></thead>
        <tbody>
          <tr :for={{p, i} <- @rows} class={if i == @picked, do: "tba-picked"}>
            <td>{p.name}</td><td>{p.pid}</td><td>{p.app}</td><td>{figure(p.work, &pct/1)}</td>
            <td>{figure(p.memory, &Human.bytes/1)}</td><td>{figure(p.queue, &count/1)}</td><td>{figure(p.reductions, &count/1)}</td>
          </tr>
        </tbody>
      </table>
      <.history detail={@detail} />
      """
    end

    defp view(%{state: %{tab: :jobs}} = assigns) do
      jobs = Enum.filter(assigns.detail.jobs, &State.wants?(assigns.state, [&1.name, &1.app]))
      picked = State.selected(assigns.state)

      assigns =
        assign(assigns, rows: Enum.with_index(jobs), picked: picked, job: Enum.at(jobs, picked))

      ~H"""
      <table>
        <thead><tr><th>STARTED</th><th>PROCS</th><th>FAILED</th><th>TOOK</th><th>JOB</th><th>APP</th></tr></thead>
        <tbody>
          <tr :for={{j, i} <- @rows} class={if i == @picked, do: "tba-picked"}>
            <td>{clock(j.started)}</td><td>{j.processes}</td>
            <td class={if j.failed > 0, do: "tba-bad"}>{if j.failed > 0, do: j.failed, else: "-"}</td>
            <td>{Human.duration(j.duration)}</td><td>{j.name}</td><td>{j.app}</td>
          </tr>
        </tbody>
      </table>
      <div :if={@job} class="tba-inspected"><pre>{Enum.join(@job.tree, "\n")}</pre></div>
      <p :if={@rows == []}>No jobs in the quarter of an hour before. A job is more than one process.</p>
      """
    end

    defp view(%{state: %{tab: :exits}} = assigns) do
      exits = Enum.filter(assigns.detail.exits, &View.wanted_exit?(assigns.state, &1))

      assigns =
        assign(assigns, rows: Enum.with_index(exits), picked: State.selected(assigns.state))

      ~H"""
      <table>
        <thead><tr><th>ENDED</th><th>PID</th><th>STATUS</th><th>TOOK</th><th>REDS</th><th>PEAK MEM</th><th>PROCESS</th></tr></thead>
        <tbody>
          <tr :for={{e, i} <- @rows} class={if i == @picked, do: "tba-picked"}>
            <td>{clock(e.at)}</td><td>{e.pid}</td>
            <td class={level(e.level)}>{e.status}</td>
            <td>{took(e)}</td><td>{figure(e.reductions, &count/1)}</td>
            <td>{figure(e.peak_memory, &Human.bytes/1)}</td><td>{e.process}</td>
          </tr>
        </tbody>
      </table>
      """
    end

    attr(:extra, :atom, required: true)
    attr(:data, :any, required: true)

    defp extra_view(%{data: {:error, why}} = assigns) do
      assigns = assign(assigns, why: why)

      ~H"""
      <div class="tba-bad">{@why}</div>
      """
    end

    defp extra_view(%{extra: :node} = assigns) do
      tiles =
        for tile <- assigns.data || [] do
          data = View.columns(tile.points, tile.to, tile.to - tile.from, @columns, tile.step)
          last = tile.points |> List.last() |> then(&(&1 && elem(&1, 1)))

          Map.merge(tile, %{
            bars: Enum.with_index(data),
            highest: Enum.max([0.0 | data]),
            last: last
          })
        end

      assigns = assign(assigns, tiles: tiles)

      ~H"""
      <div :for={tile <- @tiles} style="margin-bottom: 0.5rem">
        <small>{tile.label}: <strong>{said(tile.last, tile.kind)}</strong>, up to {said(tile.highest, tile.kind)} over the timeline</small>
        <svg class="tba-history" style="height: 2rem" viewBox={"0 0 #{columns()} 20"} preserveAspectRatio="none">
          <rect :for={{value, column} <- tile.bars} x={column} width="0.9"
                y={20 - bar(value, tile.highest, 20)} height={bar(value, tile.highest, 20)} fill="#3a7bd5" />
        </svg>
      </div>
      """
    end

    defp extra_view(%{extra: :remarks} = assigns) do
      assigns = assign(assigns, rows: assigns.data || [])

      ~H"""
      <table :if={@rows != []}>
        <thead><tr><th>WHEN</th><th>PID</th><th>WHAT</th><th>PROCESS</th><th>MEASURED</th></tr></thead>
        <tbody>
          <tr :for={r <- @rows}>
            <td>{clock(r.at)}</td><td>{r.pid}</td><td class={level(r.level)}>{r.status}</td>
            <td>{r.process}</td><td>{measured(r.fields)}</td>
          </tr>
        </tbody>
      </table>
      <p :if={@rows == []}>The VM remarked on nothing over the timeline: no long collection, no long queue, no large heap.</p>
      """
    end

    defp extra_view(%{extra: :collector} = assigns) do
      assigns = assign(assigns, rows: assigns.data || [])

      ~H"""
      <table :if={@rows != []}>
        <tbody>
          <tr :for={{metric, value} <- @rows}><td>{metric}</td><td>{plain(value)}</td></tr>
        </tbody>
      </table>
      <p :if={@rows == []}>The collector said nothing of itself at this moment.</p>
      """
    end

    # A figure as it is: a count as a count.
    defp plain(value) when value == trunc(value), do: Integer.to_string(trunc(value))
    defp plain(value), do: Human.fixed(value, 3)

    defp said(nil, _kind), do: "-"
    defp said(value, :pct), do: pct(value)
    defp said(value, :count), do: count(value)
    defp said(value, :rate), do: rate(value)
    defp said(value, :bytes), do: Human.bytes(value)

    defp measured(%{"value" => value, "unit" => "ms"}) when is_number(value),
      do: Human.duration(value / 1000)

    defp measured(%{"value" => value, "unit" => "bytes"}) when is_number(value),
      do: Human.bytes(value)

    defp measured(%{"value" => value}) when is_number(value), do: count(value)
    defp measured(_fields), do: ""

    attr(:detail, :map, required: true)

    defp history(assigns) do
      detail = assigns.detail

      data =
        View.columns(
          detail.history,
          detail.history_until,
          detail.history_span,
          @columns,
          detail.step
        )

      highest = Enum.max([0.0 | data])
      assigns = assign(assigns, data: Enum.with_index(data), highest: highest)

      ~H"""
      <div :if={@detail.history_of != ""}>
        <small>{@detail.history_of}, the {Human.duration(@detail.history_span)} before</small>
        <svg :if={@highest > 0} class="tba-history" viewBox={"0 0 #{columns()} 20"} preserveAspectRatio="none">
          <rect :for={{value, column} <- @data} x={column} width="0.9"
                y={20 - bar(value, @highest, 20)} height={bar(value, @highest, 20)} fill="#0aa" />
        </svg>
        <div :if={@highest == 0}><small>Not in the store: it has no series of its own, or none then.</small></div>
      </div>
      """
    end

    ## Figures

    defp bar(_value, highest, _height) when highest <= 0, do: 0
    defp bar(value, highest, height), do: Float.round(max(value, 0) / highest * height, 2)

    defp figure(nil, _show), do: "-"
    defp figure(value, show), do: show.(value)
    defp pct(value), do: Human.fixed(value, 1) <> "%"
    defp count(value), do: Human.count(round(value))
    defp rate(value), do: Human.fixed(value, 1)
    defp clock(at), do: at |> Clock.format() |> String.slice(11..-1//1)

    defp took(%{elapsed: nil}), do: "-"
    defp took(%{elapsed: elapsed, whole: true}), do: Human.duration(elapsed)
    defp took(%{elapsed: elapsed}), do: ">" <> Human.duration(elapsed)

    defp level("error"), do: "tba-bad"
    defp level("warning"), do: "tba-warn"
    defp level(_), do: nil

    defp tell(from, to, at) do
      text = Clock.format(at)
      if to - from >= 86_400, do: String.slice(text, 5, 11), else: String.slice(text, 11, 5)
    end
  end
end
