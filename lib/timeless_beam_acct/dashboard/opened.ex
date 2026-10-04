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

    # The chart's own coordinates: so many units across a column, and so
    # many high, scaled to the width of the card by the browser.
    @unit 10
    @chart_height 90

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
      <div class="tba" phx-window-keydown="key">
        <div class="d-flex justify-content-between align-items-center mb-3">
          <div>
            <a href={@back}>Recordings</a>
            <span class="text-muted mx-1">/</span>
            <strong>{@detail.node}</strong>
          </div>
          <div>
            <span :if={State.live?(@state)} class="badge badge-success tba-moment">
              ● live · {Clock.format(@snapshot.at)}
            </span>
            <span :if={!State.live?(@state)} class="badge badge-warning tba-moment">
              {Clock.format(@state.at)} · {Store.ago(@detail.now, @state.at)}
            </span>
          </div>
        </div>

        <div class="card mb-3">
          <div class="card-body">
            <.timeline state={@state} detail={@detail} />
          </div>
        </div>

        <div :if={@empty} class="alert alert-warning">Nothing was recorded at this moment.</div>

        <div :if={!@empty} class="row tba-stats mb-3">
          <.stat label="Schedulers" value={figure(@vm[:schedulers], &pct/1)} />
          <.stat label="CPU" value={figure(@vm[:cpu], &pct/1)} />
          <.stat label="Run queue" value={figure(@vm[:run_queue], &count/1)} />
          <.stat label="Memory" value={figure(@vm[:memory], &Human.bytes/1)} />
          <.stat label="Reductions /s" value={figure(@vm[:reductions], &count/1)} />
          <.stat
            label="Processes"
            value={figure(@vm[:processes], &count/1)}
            note={"+#{figure(@vm[:spawns], &rate/1)} −#{figure(@vm[:exits], &rate/1)} /s"}
          />
        </div>

        <ul class="nav nav-tabs mb-0">
          <li :for={{tab, n} <- Enum.with_index(State.tabs(), 1)} class="nav-item">
            <a
              class={["nav-link", tab == @state.tab and !@extra && "active"]}
              phx-click="tab"
              phx-value-tab={n}
              href="#"
            >
              {State.title(tab)} <small class="text-muted">{n}</small>
            </a>
          </li>
          <li
            :for={{extra, title, n} <- [{:node, "Node", 5}, {:remarks, "Remarks", 6}, {:collector, "Collector", 7}]}
            class="nav-item"
          >
            <a class={["nav-link", extra == @extra && "active"]} phx-click="tab" phx-value-tab={n} href="#">
              {title} <small class="text-muted">{n}</small>
            </a>
          </li>
        </ul>

        <div class="card tba-tabbed mb-3">
          <div class="card-header d-flex justify-content-between">
            <small class="text-muted">
              <span :if={!@extra and @state.tab in [:groups, :processes]}>
                sorted by <strong>{State.sort_title(@state.sort)}</strong> <kbd>s</kbd>
              </span>
              <span :if={@state.within}>
                · in <strong>{elem(@state.within, 1)}</strong> <kbd>esc</kbd>
              </span>
              <span :if={@state.typing or @state.filter != ""}>
                · only <strong>{@state.filter}{if @state.typing, do: "▏"}</strong>
              </span>
            </small>
            <small class="text-muted">{scope(@state, @extra)}</small>
          </div>

          <.inspected :if={@state.inspecting and @detail.inspected} inspected={@detail.inspected} />
          <.view :if={!@extra} state={@state} snapshot={@snapshot} detail={@detail} />
          <.extra_view :if={@extra} extra={@extra} data={@extra_data} />
        </div>

        <div :if={@state.going} class="alert alert-info py-2">
          Go to <strong>{@state.going}▏</strong>
          <small class="text-muted ml-2">now · -15m · 14:30 · 2026-09-29 14:30 · enter to go, esc to stay</small>
        </div>
        <div :if={@detail.error} class="alert alert-danger py-2">{@detail.error}</div>
        <div :if={@state.message} class="alert alert-warning py-2">{@state.message}</div>

        <p class="text-muted small tba-keys">
          <kbd>←</kbd><kbd>→</kbd> a reading · <kbd>,</kbd><kbd>.</kbd> a minute ·
          <kbd>&lt;</kbd><kbd>&gt;</kbd> ten · <kbd>[</kbd><kbd>]</kbd> an hour ·
          <kbd>t</kbd> go to · <kbd>l</kbd> live · <kbd>−</kbd><kbd>+</kbd> zoom ·
          <kbd>1</kbd>–<kbd>7</kbd> views · <kbd>↑</kbd><kbd>↓</kbd> row · <kbd>enter</kbd> open ·
          <kbd>m</kbd> its moment · <kbd>/</kbd> only · <kbd>q</kbd> back · or click the timeline
        </p>
      </div>
      """
    end

    defp scope(_state, :node), do: "over the whole timeline"
    defp scope(_state, :remarks), do: "over the timeline, up to the moment"
    defp scope(_state, :collector), do: "as of the moment"

    defp scope(%State{tab: tab}, nil) when tab in [:jobs, :exits],
      do: "the quarter of an hour before"

    defp scope(_state, nil), do: "as of the moment"

    attr(:label, :string, required: true)
    attr(:value, :string, required: true)
    attr(:note, :string, default: nil)

    defp stat(assigns) do
      ~H"""
      <div class="col-6 col-md-4 col-lg-2 mb-2 d-flex">
        <div class="banner-card w-100">
          <h6 class="banner-card-title">{@label}</h6>
          <div class="banner-card-value">{@value}</div>
          <small :if={@note} class="text-muted">{@note}</small>
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

      # Now, on a recording that is running, is where it has got to, and
      # what lies after it is still to come.
      now = assigns.detail.now
      upto = if to > from, do: min(max((now - from) / (to - from), 0.0), 1.0), else: 1.0

      cursor =
        case assigns.state.at do
          nil when to > from -> min(trunc(upto * @columns), @columns - 1)
          _ -> Enum.find_index(marks, &(&1 in [:here, :here_fault, :here_killed]))
        end

      assigns =
        assign(assigns,
          bars: Enum.with_index(bars),
          marks: Enum.with_index(marks),
          highest: highest,
          cursor: cursor,
          future: if(upto < 1.0, do: upto * @columns * @unit),
          from: from,
          to: to,
          width: @columns * @unit,
          unit: @unit,
          height: @chart_height
        )

      ~H"""
      <div class="d-flex justify-content-between mb-1">
        <h6 class="card-title mb-0">Schedulers</h6>
        <small class="text-muted">
          busiest {Human.fixed(@highest, 1)}%
          · <span class="tba-fault">■</span> raised · <span class="tba-kill">■</span> killed
        </small>
      </div>
      <svg
        class="tba-chart"
        viewBox={"0 0 #{@width} #{@height + 14}"}
        preserveAspectRatio="none"
        style="height: 104px"
      >
        <rect :if={@future} x={@future} y="0" width={@width - @future} height={@height} class="tba-future" />
        <line x1="0" x2={@width} y1={@height} y2={@height} class="tba-axis" />
        <rect
          :for={{value, column} <- @bars}
          x={column * @unit + 1}
          width={@unit - 2}
          y={@height - bar(value, @highest, @height - 4)}
          height={bar(value, @highest, @height - 4)}
          class="tba-bar"
        />
        <g :for={{mark, column} <- @marks}>
          <rect
            :if={mark in [:fault, :here_fault]}
            x={column * @unit + 2}
            y={@height + 4}
            width={@unit - 4}
            height="8"
            class="tba-fault"
          />
          <rect
            :if={mark in [:killed, :here_killed]}
            x={column * @unit + 3}
            y={@height + 6}
            width={@unit - 6}
            height="4"
            class="tba-kill"
          />
        </g>
        <line
          :if={@cursor}
          x1={@cursor * @unit + @unit / 2}
          x2={@cursor * @unit + @unit / 2}
          y1="0"
          y2={@height}
          class="tba-cursor"
        />
        <rect
          :for={column <- 0..(columns() - 1)}
          x={column * @unit}
          y="0"
          width={@unit}
          height={@height + 14}
          class="tba-hit"
          phx-click="goto"
          phx-value-column={column}
        />
      </svg>
      <div :if={@to > @from} class="d-flex justify-content-between">
        <small class="text-muted">{tell(@from, @to, @from)}</small>
        <small class="text-muted">{Human.duration(@to - @from)}</small>
        <small class="text-muted">{tell(@from, @to, @to)}</small>
      </div>
      """
    end

    attr(:inspected, :any, required: true)

    defp inspected(assigns) do
      ~H"""
      <div class="card-body border-bottom tba-inspected">
        <div class="d-flex justify-content-between mb-2">
          <strong>{elem(@inspected, 0)}</strong>
          <small class="text-muted">any key to close</small>
        </div>
        <dl class="row mb-0">
          <%= for {label, value} <- elem(@inspected, 1) do %>
            <dt class="col-sm-2 text-muted font-weight-normal">{label}</dt>
            <dd class="col-sm-10 mb-1">{value}</dd>
          <% end %>
        </dl>
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
      <div class="tba-scroll">
        <table class="table table-sm table-hover mb-0">
          <thead>
            <tr>
              <th>{if @state.apps, do: "Application", else: "Group"}</th>
              <th class="text-right">Work</th>
              <th class="text-right">Memory</th>
              <th class="text-right">Processes</th>
              <th class="text-right">Queue</th>
              <th class="text-right">Reds /s</th>
              <th class="text-right">Ended /s</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{g, i} <- @rows} class={i == @picked && "table-active"}>
              <td class="tba-name">{g.name}</td>
              <td class="text-right">{figure(g.work, &pct/1)}</td>
              <td class="text-right">{figure(g.memory, &Human.bytes/1)}</td>
              <td class="text-right">{figure(g.processes, &count/1)}</td>
              <td class="text-right">{figure(g.queue, &count/1)}</td>
              <td class="text-right">{figure(g.reductions, &count/1)}</td>
              <td class="text-right">{figure(g.exits, &rate/1)}</td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="7" class="text-center text-muted py-4">Nothing at this moment.</td>
            </tr>
          </tbody>
        </table>
      </div>
      <.history detail={@detail} />
      """
    end

    defp view(%{state: %{tab: :processes}} = assigns) do
      rows = State.processes(assigns.state, assigns.snapshot)

      assigns =
        assign(assigns, rows: Enum.with_index(rows), picked: State.selected(assigns.state))

      ~H"""
      <div class="tba-scroll">
        <table class="table table-sm table-hover mb-0">
          <thead>
            <tr>
              <th>Process</th>
              <th>Pid</th>
              <th>Application</th>
              <th class="text-right">Work</th>
              <th class="text-right">Memory</th>
              <th class="text-right">Queue</th>
              <th class="text-right">Reductions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{p, i} <- @rows} class={i == @picked && "table-active"}>
              <td class="tba-name">{p.name}</td>
              <td class="text-monospace small">{p.pid}</td>
              <td>{p.app}</td>
              <td class="text-right">{figure(p.work, &pct/1)}</td>
              <td class="text-right">{figure(p.memory, &Human.bytes/1)}</td>
              <td class="text-right">{figure(p.queue, &count/1)}</td>
              <td class="text-right">{figure(p.reductions, &count/1)}</td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="7" class="text-center text-muted py-4">
                No process had series of its own at this moment.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <.history detail={@detail} />
      """
    end

    defp view(%{state: %{tab: :jobs}} = assigns) do
      jobs = Enum.filter(assigns.detail.jobs, &State.wants?(assigns.state, [&1.name, &1.app]))
      picked = State.selected(assigns.state)

      assigns =
        assign(assigns, rows: Enum.with_index(jobs), picked: picked, job: Enum.at(jobs, picked))

      ~H"""
      <div class="tba-scroll tba-scroll-short">
        <table class="table table-sm table-hover mb-0">
          <thead>
            <tr>
              <th>Started</th>
              <th class="text-right">Processes</th>
              <th class="text-right">Failed</th>
              <th class="text-right">Took</th>
              <th>Job</th>
              <th>Application</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{j, i} <- @rows} class={i == @picked && "table-active"}>
              <td class="text-monospace small">{clock(j.started)}</td>
              <td class="text-right">{j.processes}</td>
              <td class={["text-right", j.failed > 0 && "text-danger"]}>
                {if j.failed > 0, do: j.failed, else: "–"}
              </td>
              <td class="text-right">{Human.duration(j.duration)}</td>
              <td class="tba-name">{j.name}</td>
              <td>{j.app}</td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="6" class="text-center text-muted py-4">
                No jobs in the quarter of an hour before. A job is more than one process.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div :if={@job} class="card-body border-top">
        <h6 class="card-title">What it was</h6>
        <pre class="tba-tree mb-0">{Enum.join(@job.tree, "\n")}</pre>
      </div>
      """
    end

    defp view(%{state: %{tab: :exits}} = assigns) do
      exits = Enum.filter(assigns.detail.exits, &View.wanted_exit?(assigns.state, &1))

      assigns =
        assign(assigns, rows: Enum.with_index(exits), picked: State.selected(assigns.state))

      ~H"""
      <div class="tba-scroll">
        <table class="table table-sm table-hover mb-0">
          <thead>
            <tr>
              <th>Ended</th>
              <th>Pid</th>
              <th>Status</th>
              <th class="text-right">Took</th>
              <th class="text-right">Reductions</th>
              <th class="text-right">Peak memory</th>
              <th>Process</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{e, i} <- @rows} class={i == @picked && "table-active"}>
              <td class="text-monospace small">{clock(e.at)}</td>
              <td class="text-monospace small">{e.pid}</td>
              <td><span class={["badge", level(e.level)]}>{e.status}</span></td>
              <td class="text-right">{took(e)}</td>
              <td class="text-right">{figure(e.reductions, &count/1)}</td>
              <td class="text-right">{figure(e.peak_memory, &Human.bytes/1)}</td>
              <td class="tba-name">{e.process}</td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="7" class="text-center text-muted py-4">
                Nothing ended in the quarter of an hour before.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      """
    end

    attr(:extra, :atom, required: true)
    attr(:data, :any, required: true)

    defp extra_view(%{data: {:error, why}} = assigns) do
      assigns = assign(assigns, why: why)

      ~H"""
      <div class="card-body text-danger">{@why}</div>
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

      assigns = assign(assigns, tiles: tiles, width: @columns * @unit, unit: @unit)

      ~H"""
      <div class="card-body">
        <div class="row">
          <div :for={tile <- @tiles} class="col-md-6 col-lg-4 mb-3">
            <div class="d-flex justify-content-between">
              <small class="text-muted">{tile.label}</small>
              <small>
                <strong>{said(tile.last, tile.kind)}</strong>
                <span class="text-muted">· peak {said(tile.highest, tile.kind)}</span>
              </small>
            </div>
            <svg class="tba-chart" viewBox={"0 0 #{@width} 40"} preserveAspectRatio="none" style="height: 40px">
              <line x1="0" x2={@width} y1="40" y2="40" class="tba-axis" />
              <rect
                :for={{value, column} <- tile.bars}
                x={column * @unit + 1}
                width={@unit - 2}
                y={40 - bar(value, tile.highest, 38)}
                height={bar(value, tile.highest, 38)}
                class="tba-bar"
              />
            </svg>
          </div>
        </div>
      </div>
      """
    end

    defp extra_view(%{extra: :remarks} = assigns) do
      assigns = assign(assigns, rows: assigns.data || [])

      ~H"""
      <div class="tba-scroll">
        <table class="table table-sm table-hover mb-0">
          <thead>
            <tr>
              <th>When</th>
              <th>Pid</th>
              <th>What</th>
              <th>Process</th>
              <th class="text-right">Measured</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- @rows}>
              <td class="text-monospace small">{clock(r.at)}</td>
              <td class="text-monospace small">{r.pid}</td>
              <td><span class={["badge", level(r.level)]}>{r.status}</span></td>
              <td class="tba-name">{r.process}</td>
              <td class="text-right">{measured(r.fields)}</td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="5" class="text-center text-muted py-4">
                The VM remarked on nothing: no long collection, no long queue, no large heap.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      """
    end

    defp extra_view(%{extra: :collector} = assigns) do
      assigns = assign(assigns, rows: assigns.data || [])

      ~H"""
      <table class="table table-sm mb-0">
        <tbody>
          <tr :for={{metric, value} <- @rows}>
            <td class="text-monospace small">{metric}</td>
            <td class="text-right">{plain(value)}</td>
          </tr>
          <tr :if={@rows == []}>
            <td colspan="2" class="text-center text-muted py-4">
              The collector said nothing of itself at this moment.
            </td>
          </tr>
        </tbody>
      </table>
      """
    end

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

      assigns =
        assign(assigns,
          data: Enum.with_index(data),
          highest: highest,
          width: @columns * @unit,
          unit: @unit
        )

      ~H"""
      <div :if={@detail.history_of != ""} class="card-body border-top">
        <div class="d-flex justify-content-between">
          <small class="text-muted">
            <strong>{@detail.history_of}</strong>, the {Human.duration(@detail.history_span)} before
          </small>
          <small :if={@highest > 0} class="text-muted">peak {history_peak(@highest, @detail.history_kind)}</small>
        </div>
        <svg :if={@highest > 0} class="tba-chart" viewBox={"0 0 #{@width} 50"} preserveAspectRatio="none" style="height: 50px">
          <line x1="0" x2={@width} y1="50" y2="50" class="tba-axis" />
          <rect
            :for={{value, column} <- @data}
            x={column * @unit + 1}
            width={@unit - 2}
            y={50 - bar(value, @highest, 48)}
            height={bar(value, @highest, 48)}
            class="tba-bar tba-bar-alt"
          />
        </svg>
        <div :if={@highest == 0}>
          <small class="text-muted">Not in the store: it has no series of its own, or none then.</small>
        </div>
      </div>
      """
    end

    defp history_peak(peak, :memory), do: Human.bytes(peak)
    defp history_peak(peak, :queue), do: count(peak) <> " waiting"
    defp history_peak(peak, _), do: pct(peak)

    ## Figures

    defp bar(_value, highest, _height) when highest <= 0, do: 0
    defp bar(value, highest, height), do: Float.round(max(value, 0) / highest * height, 2)

    defp figure(nil, _show), do: "–"
    defp figure(value, show), do: show.(value)
    defp pct(value), do: Human.fixed(value, 1) <> "%"
    defp count(value), do: Human.count(round(value))
    defp rate(value), do: Human.fixed(value, 1)
    defp clock(at), do: at |> Clock.format() |> String.slice(11..-1//1)

    # A figure as it is: a count as a count.
    defp plain(value) when value == trunc(value), do: Integer.to_string(trunc(value))
    defp plain(value), do: Human.fixed(value, 3)

    defp said(nil, _kind), do: "–"
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

    defp took(%{elapsed: nil}), do: "–"
    defp took(%{elapsed: elapsed, whole: true}), do: Human.duration(elapsed)
    defp took(%{elapsed: elapsed}), do: ">" <> Human.duration(elapsed)

    defp level("error"), do: "badge-danger"
    defp level("warning"), do: "badge-warning"
    defp level("notice"), do: "badge-info"
    defp level(_), do: "badge-light"

    defp tell(from, to, at) do
      text = Clock.format(at)
      if to - from >= 86_400, do: String.slice(text, 5, 11), else: String.slice(text, 11, 8)
    end
  end
end
