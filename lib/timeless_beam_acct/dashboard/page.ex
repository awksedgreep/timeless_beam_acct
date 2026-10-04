if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
  defmodule TimelessBeamAcct.Dashboard.Page do
    @moduledoc """
    The recordings of a node, in Phoenix LiveDashboard: the one that is
    running, with how long it has left, and those that were made.

    Compiled only where LiveDashboard is. Added to a dashboard with
    `TimelessBeamAcct.Dashboard.Router`, or among `additional_pages`:

        live_dashboard "/dashboard",
          additional_pages: [beam: TimelessBeamAcct.Dashboard.Page]

    Where the planes are is said in the configuration, as the collector is
    told:

        config :timeless_beam_acct, :dashboard,
          metrics_url: "http://127.0.0.1:8428",
          logs_url: "http://127.0.0.1:9428",
          traces_url: "http://127.0.0.1:10428"

    The node is LiveDashboard's: whichever is chosen at the top of the
    page.
    """

    use Phoenix.LiveDashboard.PageBuilder, refresher?: true

    alias TimelessBeamAcct.{Clock, Human, Remote}
    alias TimelessBeamAcct.Dashboard.Opened
    alias TimelessBeamAcct.Watch.{Live, Planes, State, Store}

    @lengths [{"15m", "15 minutes"}, {"1h", "1 hour"}, {"4h", "4 hours"}, {"8h", "8 hours"}]

    # A collector the page starts where one is running already, that is
    # not a recording: the application's own, started with it. The
    # recording runs beside it, under this name, until its time is up.
    @beside TimelessBeamAcct.Recorded
    @plane_keys [:metrics_url, :logs_url, :traces_url, :token, :metrics_token, :logs_token] ++
                  [:traces_token]

    # How far back the recordings are listed.
    @listed 31 * 86_400.0

    @impl true
    def menu_link(_session, _capabilities), do: {:ok, "TimelessAcct"}

    @impl true
    def mount(_params, _session, socket) do
      socket =
        socket
        |> assign(said: nil, watch: nil, extra: nil, extra_data: nil, estimate: nil, paced: nil)
        |> read()

      {:ok, socket}
    end

    # A recording is opened by its id in the query string, so that it can
    # be sent to someone.
    @impl true
    def handle_params(%{"recording" => id}, uri, socket) when id != "" do
      socket = assign(socket, here: URI.parse(uri).path)

      case Opened.open(id, Keyword.take(configured(), @plane_keys)) do
        {:ok, watch} ->
          {:noreply, assign(socket, watch: watch, said: nil, back: socket.assigns.here)}

        {:error, why} ->
          {:noreply, socket |> assign(watch: nil, said: why) |> read()}
      end
    end

    def handle_params(_params, uri, socket),
      do: {:noreply, assign(socket, watch: nil, here: URI.parse(uri).path)}

    # An opened recording refreshes while it is of now, and a moment that
    # has passed does not change.
    @impl true
    def handle_refresh(%{assigns: %{watch: %{} = watch}} = socket) do
      if State.live?(watch.state),
        do:
          {:noreply,
           showing(socket, TimelessBeamAcct.Watch.read_moment(watch), socket.assigns.extra)},
        else: {:noreply, socket}
    end

    def handle_refresh(socket), do: {:noreply, read(socket)}

    # How fast the chosen node starts processes is measured over a few
    # seconds, apart from the page, and is what the form says of the cost.
    @impl true
    def handle_info({ref, {:paced, node, paced}}, socket) when is_reference(ref) do
      Process.demonitor(ref, [:flush])

      estimate =
        case paced do
          {:ok, rate} -> TimelessBeamAcct.Recording.estimate(rate).said
          {:error, _} -> nil
        end

      {:noreply, assign(socket, estimate: estimate, paced: node)}
    end

    def handle_info(_message, socket), do: {:noreply, socket}

    @impl true
    def handle_event("key", %{"key" => key} = params, %{assigns: %{watch: %{} = watch}} = socket) do
      case Opened.key(key, params["shiftKey"] == true) do
        nil ->
          {:noreply, socket}

        # The page's own views, which watch has not. As any key does, it
        # puts away what was drawn over the rest.
        {:char, n} when n in ["5", "6", "7"] ->
          watch = %{watch | state: %{watch.state | inspecting: false, help: false}}
          {:noreply, showing(socket, watch, Opened.extra(n))}

        pressed ->
          watch = Opened.pressed(watch, pressed)

          # One of watch's views is gone to by its number.
          extra =
            if pressed in [{:char, "1"}, {:char, "2"}, {:char, "3"}, {:char, "4"}],
              do: nil,
              else: socket.assigns.extra

          # q, or escape out of everything, is back to the recordings.
          if watch.state.quit,
            do: {:noreply, push_patch(socket, to: socket.assigns.here)},
            else: {:noreply, showing(socket, watch, extra)}
      end
    end

    def handle_event("key", _params, socket), do: {:noreply, socket}

    def handle_event("goto", %{"column" => column}, %{assigns: %{watch: %{} = watch}} = socket) do
      watch = Opened.go_to_column(watch, String.to_integer(column))
      {:noreply, showing(socket, watch, socket.assigns.extra)}
    end

    def handle_event("tab", %{"tab" => n}, %{assigns: %{watch: %{} = watch}} = socket) do
      case Opened.extra(n) do
        nil -> {:noreply, showing(socket, Opened.tab(watch, n), nil)}
        extra -> {:noreply, showing(socket, watch, extra)}
      end
    end

    def handle_event("record", _params, %{assigns: %{answering: false}} = socket) do
      {:noreply,
       assign(socket,
         said:
           "It could not be started: the Timeless planes are not answering, and a " <>
             "recording is written to them."
       )}
    end

    def handle_event("record", params, socket) do
      length = if params["length"] == "other", do: params["other"], else: params["length"]

      start_at =
        case params["start"] do
          "at" -> [start_at: params["start_at"]]
          _ -> []
        end

      name = if socket.assigns.collecting, do: @beside, else: TimelessBeamAcct

      opts =
        [name: name, stop_after: length, recorded_by: "LiveDashboard on #{node()}", sink: :http] ++
          start_at ++
          Keyword.take(configured(), @plane_keys) ++
          most() ++
          if(params["processes"] == "true", do: [], else: [max_processes: 0]) ++
          if(params["failed_only"] == "true", do: [records: :abnormal], else: [])

      # Into the node chosen; and into this one as into another, so that
      # it outlives the page that started it.
      started =
        case socket.assigns.page.node do
          here when here == node() -> Remote.start_guest(opts)
          there -> Remote.attach(there, opts)
        end

      said =
        case started do
          {:ok, _} -> "Recording."
          {:error, why} -> "It could not be started: #{why}"
        end

      {:noreply, socket |> assign(said: said) |> read()}
    end

    def handle_event("stop", _params, socket) do
      said =
        case call(socket, TimelessBeamAcct, :stop, [socket.assigns.recording_name]) do
          {:ok, :ok} -> "The recording was stopped."
          {:error, why} -> "It could not be stopped: #{why}"
          {:ok, other} -> "It could not be stopped: #{inspect(other)}"
        end

      {:noreply, socket |> assign(said: said) |> read()}
    end

    def handle_event("extend", %{"by" => by}, socket) do
      said =
        case call(socket, TimelessBeamAcct, :extend, [socket.assigns.recording_name, by]) do
          {:ok, {:ok, stop_at}} -> "It now ends at #{Clock.format(stop_at)}."
          {:ok, {:error, why}} -> why
          {:error, why} -> why
        end

      {:noreply, socket |> assign(said: said) |> read()}
    end

    # What is shown: the recording running in the node, if one is, and
    # the recordings the logs plane has.
    defp read(socket) do
      node = socket.assigns.page.node
      now = Clock.now()

      # The collector of the usual name, and one the page started beside
      # it: whichever of them is recording, or waiting to.
      statuses =
        for name <- [TimelessBeamAcct, @beside] do
          {name, Live.status(%Live{node: node, name: name})}
        end

      {recording_name, running, waiting} =
        Enum.find_value(statuses, {TimelessBeamAcct, nil, nil}, fn
          {name, {:ok, %{waiting: waiting}}} -> {name, nil, waiting}
          {name, {:ok, %{recording: %{} = recording}}} -> {name, recording, nil}
          _ -> nil
        end)

      # A collector of the usual name that is not a recording: one that is
      # running has `recording: nil`, and one that waits has no such key.
      collecting = match?({:ok, %{recording: nil}}, statuses[TimelessBeamAcct])

      storage =
        case planes() do
          {:ok, planes} -> Planes.storage(planes)
          _ -> []
        end

      # A recording is written to the planes and read from them: without
      # them there is nothing to list, and nowhere for one to go.
      {recordings, error} =
        case planes() do
          nil ->
            {[],
             "Where the Timeless planes are is not configured. A recording is written to " <>
               "them and read from them: config :timeless_beam_acct, :dashboard, " <>
               "metrics_url: ..., logs_url: ..., traces_url: ..."}

          {:error, why} ->
            {[], why}

          {:ok, planes} ->
            case Store.recordings(planes, now - @listed, now) do
              {:ok, recordings} ->
                {Enum.map(recordings, &gone(&1, now)), nil}

              {:error, why} ->
                {[],
                 "The Timeless planes are not answering (#{why}). A recording is written to " <>
                   "them and read from them, so none can be started until they answer. " <>
                   "Where they are is in config :timeless_beam_acct, :dashboard."}
            end
        end

      pace(socket, node, running || waiting)

      assign(socket,
        links: Map.new(recordings, &{&1.id, "?" <> URI.encode_query(recording: &1.id)}),
        node: node,
        storage: storage,
        now: now,
        running: running,
        collecting: collecting,
        recording_name: recording_name,
        waiting: waiting,
        recordings: recordings,
        error: error,
        answering: is_nil(error)
      )
    end

    # What is watched, and which of the page's own views is shown, read as
    # of the moment.
    defp showing(socket, watch, extra),
      do: assign(socket, watch: watch, extra: extra, extra_data: Opened.read_extra(watch, extra))

    # Measured once for each node chosen, where a recording could be started.
    defp pace(socket, node, recording) do
      if is_nil(recording) and socket.assigns[:paced] != node and connected?(socket) do
        Task.async(fn -> {:paced, node, Remote.pace(node, 3)} end)
      end

      :ok
    end

    defp configured, do: Application.get_env(:timeless_beam_acct, :dashboard, [])

    # A recording that has said nothing of its end, and whose time is not
    # up, is asked after where its node can be asked: one whose node was
    # started again since is not shown as recording until its time would
    # have run out.
    defp gone(%{ended: nil, stop_at: stop_at} = recording, now) when stop_at > now do
      case Store.making(recording) do
        :ended -> Map.put(recording, :gone, true)
        _recording_or_unknown -> recording
      end
    end

    defp gone(recording, _now), do: recording

    # The longest a recording may be, as this application says: told to
    # the node recorded, which would otherwise keep its own, and let a
    # recording be extended past this one's.
    defp most do
      case Application.get_env(:timeless_beam_acct, :max_recording) do
        nil -> []
        most -> [max_recording: most]
      end
    end

    defp planes do
      case configured() do
        [] -> nil
        configured -> Planes.new(Keyword.take(configured, @plane_keys))
      end
    end

    @doc false
    def lengths, do: @lengths

    defp call(socket, module, function, args) do
      {:ok, :erpc.call(socket.assigns.page.node, module, function, args, 30_000)}
    catch
      kind, reason -> {:error, Exception.format_banner(kind, reason)}
    end

    @impl true
    def render(%{watch: %{} = watch} = assigns) do
      assigns = assign(assigns, opened: watch)

      ~H"""
      <.styles />
      <Opened.recording watch={@opened} back={@back} extra={@extra} extra_data={@extra_data} />
      """
    end

    def render(assigns) do
      ~H"""
      <.styles />
      <div class="tba">
        <div :if={@said} class="alert alert-info py-2">{@said}</div>

        <div :if={@running} class="card mb-4">
          <div class="card-body">
            <div class="d-flex justify-content-between align-items-start">
              <div>
                <h5 class="card-title mb-1">
                  <span class="badge badge-danger tba-rec">● REC</span> Recording {@node}
                </h5>
                <small class="text-muted">
                  started {Clock.format(@running.started)}{if @running.by, do: " by #{@running.by}"}
                  · ends by itself at {Clock.format(@running.stop_at)}
                </small>
              </div>
              <div class="text-nowrap">
                <button phx-click="extend" phx-value-by="1h" class="btn btn-sm btn-outline-secondary">
                  +1 hour
                </button>
                <button phx-click="stop" data-confirm="Stop this recording now?" class="btn btn-sm btn-danger ml-1">
                  Stop
                </button>
              </div>
            </div>
            <div class="progress mt-3" style="height: 6px">
              <div class="progress-bar" role="progressbar" style={"width: #{progress(@running, @now)}%"}></div>
            </div>
            <div class="d-flex justify-content-between mt-1">
              <small class="text-muted">{Human.duration(@now - @running.started)} recorded</small>
              <small class="text-muted">{Human.duration(max(@running.stop_at - @now, 0))} left</small>
            </div>
          </div>
        </div>

        <div :if={@waiting} class="card mb-4">
          <div class="card-body d-flex justify-content-between align-items-center">
            <div>
              <h5 class="card-title mb-1">{@node} is to be recorded</h5>
              <small class="text-muted">
                from {Clock.format(@waiting.start_at)}, for {Human.duration(@waiting.stop_after)}{if @waiting.by,
                  do: ", as asked by #{@waiting.by}"}. Until then it waits, and reads nothing.
              </small>
            </div>
            <button phx-click="stop" data-confirm="Call this recording off?" class="btn btn-sm btn-outline-danger">
              Call it off
            </button>
          </div>
        </div>

        <div :if={@error} class="alert alert-warning py-2">{@error}</div>

        <div :if={!@running and !@waiting} class="card mb-4">
          <div class="card-body">
            <h5 class="card-title">Record {@node}</h5>
            <p :if={@collecting} class="small text-muted">
              A collector is running here already, and is not a recording: it runs until it is
              stopped. A recording runs beside it, for as long as you say, and the two are
              listening while it does.
            </p>
            <form phx-submit="record">
              <div class="form-group row mb-2">
                <label class="col-sm-2 col-form-label col-form-label-sm text-muted">For</label>
                <div class="col-sm-10 d-flex align-items-center flex-wrap">
                  <div :for={{value, label} <- lengths()} class="form-check form-check-inline">
                    <input class="form-check-input" type="radio" name="length" id={"len-#{value}"} value={value} checked={value == "1h"} />
                    <label class="form-check-label" for={"len-#{value}"}>{label}</label>
                  </div>
                  <div class="form-check form-check-inline">
                    <input class="form-check-input" type="radio" name="length" id="len-other" value="other" />
                    <input type="text" name="other" placeholder="90m" class="form-control form-control-sm" style="width: 5rem" />
                  </div>
                </div>
              </div>
              <div class="form-group row mb-2">
                <label class="col-sm-2 col-form-label col-form-label-sm text-muted">Start</label>
                <div class="col-sm-10 d-flex align-items-center flex-wrap">
                  <div class="form-check form-check-inline">
                    <input class="form-check-input" type="radio" name="start" id="start-now" value="now" checked />
                    <label class="form-check-label" for="start-now">now</label>
                  </div>
                  <div class="form-check form-check-inline">
                    <input class="form-check-input" type="radio" name="start" id="start-at" value="at" />
                    <label class="form-check-label mr-2" for="start-at">at</label>
                    <input type="text" name="start_at" placeholder="01:55" class="form-control form-control-sm" style="width: 6rem" />
                  </div>
                  <small class="text-muted">the node's time; a time that has passed today is tomorrow</small>
                </div>
              </div>
              <div class="form-group row mb-3">
                <label class="col-sm-2 col-form-label col-form-label-sm text-muted">Keep</label>
                <div class="col-sm-10">
                  <div class="form-check">
                    <input class="form-check-input" type="checkbox" name="processes" value="true" id="keep-processes" checked />
                    <label class="form-check-label" for="keep-processes">
                      a series for each notable process <small class="text-muted">(more to look at, more to store)</small>
                    </label>
                  </div>
                  <div class="form-check">
                    <input class="form-check-input" type="checkbox" name="failed_only" value="true" id="keep-failed" />
                    <label class="form-check-label" for="keep-failed">
                      a record only of processes that failed <small class="text-muted">(less to store on a busy node)</small>
                    </label>
                  </div>
                </div>
              </div>
              <div class="d-flex justify-content-between align-items-center">
                <small class="text-muted">
                  {@estimate || "A recording costs a node about 5% of one core where 65 processes end a second, and less where fewer do."}
                  It ends by itself; a day at most.
                </small>
                <button
                  type="submit"
                  disabled={@error != nil}
                  data-confirm={"Record #{@node}?"}
                  class="btn btn-primary btn-sm ml-3"
                >
                  Record
                </button>
              </div>
            </form>
          </div>
        </div>

        <div class="card">
          <div class="card-header d-flex justify-content-between">
            <span>Recordings</span>
            <small class="text-muted">the last 31 days · click one to go through it</small>
          </div>
          <table class="table table-sm table-hover mb-0">
            <thead>
              <tr>
                <th>Started</th>
                <th>Node</th>
                <th class="text-right">Length</th>
                <th>Ended</th>
                <th>By</th>
                <th class="text-right">Id</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={r <- @recordings}>
                <td><a href={@links[r.id]}>{Clock.format(r.started)}</a></td>
                <td>{r.node}</td>
                <td class="text-right">{length_of(r, @now)}</td>
                <td><span class={["badge", badge(r, @now)]}>{how(r, @now)}</span></td>
                <td class="text-muted">{r.by}</td>
                <td class="text-right"><a href={@links[r.id]} class="text-monospace small">{String.slice(r.id, 0, 8)}</a></td>
              </tr>
              <tr :if={@recordings == [] and !@error}>
                <td colspan="6" class="text-center text-muted py-4">No recordings in the last 31 days.</td>
              </tr>
            </tbody>
          </table>
        </div>

        <.storage :if={@storage != []} storage={@storage} />
      </div>
      """
    end

    attr(:storage, :list, required: true)

    # What the planes hold, and how small they hold it.
    defp storage(assigns) do
      totals =
        Enum.reduce(assigns.storage, %{raw: 0, data: 0, disk: 0}, fn s, t ->
          %{raw: t.raw + s.raw, data: t.data + s.data, disk: t.disk + s.disk}
        end)

      assigns = assign(assigns, totals: totals)

      ~H"""
      <div class="card mt-4">
        <div class="card-header d-flex justify-content-between">
          <span>Storage</span>
          <small class="text-muted">all the planes hold, not one recording</small>
        </div>
        <table class="table table-sm mb-0">
          <thead>
            <tr>
              <th></th>
              <th class="text-right">Stored</th>
              <th class="text-right">Raw</th>
              <th class="text-right">Compressed</th>
              <th class="text-right">Each</th>
              <th class="text-right">Compression</th>
              <th class="text-right text-muted">On disk, with indexes</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @storage}>
              <td>{signal(s.signal)}</td>
              <td class="text-right">{Human.count(s.items)}</td>
              <td class="text-right">{Human.bytes(s.raw)}</td>
              <td class="text-right">{Human.bytes(s.data)}</td>
              <td class="text-right">{each(s.data, s.items)}</td>
              <td class="text-right"><strong>{smaller(s.raw, s.data)}</strong></td>
              <td class="text-right text-muted">{Human.bytes(s.disk)}</td>
              <td class="text-muted small">{s.detail}</td>
            </tr>
          </tbody>
          <tfoot>
            <tr>
              <td><strong>All of it</strong></td>
              <td></td>
              <td class="text-right">{Human.bytes(@totals.raw)}</td>
              <td class="text-right">{Human.bytes(@totals.data)}</td>
              <td></td>
              <td class="text-right"><strong>{smaller(@totals.raw, @totals.data)}</strong></td>
              <td class="text-right text-muted">{Human.bytes(@totals.disk)}</td>
              <td></td>
            </tr>
          </tfoot>
        </table>
        <p class="text-muted small mb-0 px-3 py-2">
          Compression is of raw, as the planes count it, against what it was compressed to;
          indexes are on disk beside it, and not in it.
        </p>
      </div>
      """
    end

    defp signal(:samples), do: "Samples"
    defp signal(:records), do: "Exit records"
    defp signal(:spans), do: "Spans"

    defp each(_bytes, 0), do: "–"

    defp each(bytes, items) do
      per = bytes / items
      if per < 10, do: Human.fixed(per, 2) <> " B", else: Human.fixed(per, 1) <> " B"
    end

    # As a share saved, and as a ratio: 93% (14:1).
    defp smaller(raw, disk) when raw > 0 and disk > 0,
      do: "#{round(100 * (1 - disk / raw))}% (#{round(raw / disk)}:1)"

    defp smaller(_raw, _disk), do: "–"

    # What the page draws with, beside LiveDashboard's own.
    defp styles(assigns) do
      ~H"""
      <style>
        .tba .tba-moment { font-size: 0.9rem; font-weight: 500; padding: 0.4em 0.7em; }
        .tba .tba-rec { font-size: 0.7rem; vertical-align: middle; }
        .tba svg.tba-chart { width: 100%; display: block; }
        .tba .tba-axis { stroke: rgba(0, 0, 0, 0.15); stroke-width: 1; }
        .tba .tba-bar { fill: #6c8fd5; }
        .tba .tba-bar-alt { fill: #3fa7a0; }
        .tba .tba-fault { fill: #dc3545; color: #dc3545; }
        .tba .tba-kill { fill: #e0a800; color: #e0a800; }
        .tba .tba-cursor { stroke: #212529; stroke-width: 2; stroke-dasharray: 4 3; }
        .tba .tba-hit { fill: transparent; cursor: pointer; }
        .tba .tba-hit:hover { fill: rgba(0, 0, 0, 0.06); }
        .tba .nav-tabs .nav-link { cursor: pointer; }
        .tba .tba-tabbed { border-top-left-radius: 0; border-top: 0; }
        .tba .tba-scroll { max-height: 26rem; overflow-y: auto; }
        .tba .tba-scroll-short { max-height: 16rem; }
        .tba .tba-scroll thead th { position: sticky; top: 0; background: #fff; z-index: 1; }
        .tba table td, .tba table th { white-space: nowrap; padding-left: 0.75rem; padding-right: 0.75rem; }
        .tba table td:first-child, .tba table th:first-child { padding-left: 1.25rem; }
        .tba table td:last-child, .tba table th:last-child { padding-right: 1.25rem; }
        .tba .tba-stats .banner-card { min-height: 0; height: auto !important; padding: 0.6rem 1rem; }
        .tba .tba-stats .banner-card-title { margin-bottom: 0.15rem; }
        .tba .tba-future { fill: rgba(0, 0, 0, 0.035); }
        .tba .tba-name { max-width: 28rem; overflow: hidden; text-overflow: ellipsis; }
        .tba .text-right { font-variant-numeric: tabular-nums; }
        .tba .tba-stats .banner-card-value { font-size: 1.4rem; }
        .tba pre.tba-tree { font-size: 0.8rem; white-space: pre; overflow-x: auto; }
        .tba kbd { font-size: 0.7rem; padding: 0.1rem 0.3rem; margin: 0 1px; }
        .tba .tba-keys { line-height: 1.9; }
      </style>
      """
    end

    defp badge(%{gone: true}, _now), do: "badge-warning"
    defp badge(%{ended: ended, reason: "time"}, _now) when is_number(ended), do: "badge-success"

    defp badge(%{ended: ended, reason: "stopped"}, _now) when is_number(ended),
      do: "badge-secondary"

    defp badge(%{ended: ended}, _now) when is_number(ended), do: "badge-warning"
    defp badge(%{stop_at: stop_at}, now) when stop_at > now, do: "badge-danger"
    defp badge(_recording, _now), do: "badge-warning"

    defp progress(recording, now) do
      length = max(recording.stop_at - recording.started, 1.0)
      Float.round(min(max((now - recording.started) / length, 0.0), 1.0) * 100, 1)
    end

    defp length_of(%{gone: true}, _now), do: "-"

    defp length_of(%{ended: ended, started: started}, _now) when is_number(ended),
      do: Human.duration(ended - started)

    defp length_of(%{stop_at: stop_at, started: started}, now) when stop_at > now,
      do: Human.duration(now - started) <> " so far"

    defp length_of(_recording, _now), do: "-"

    defp how(%{gone: true}, _now), do: "its node ended first"
    defp how(%{ended: ended, reason: "time"}, _now) when is_number(ended), do: "its time ran out"
    defp how(%{ended: ended, reason: "stopped"}, _now) when is_number(ended), do: "it was stopped"
    defp how(%{ended: ended}, _now) when is_number(ended), do: "what it ran in went first"

    defp how(%{stop_at: stop_at}, now) when stop_at > now, do: "recording"

    defp how(_recording, _now), do: "its node ended first"
  end
end
