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
    @plane_keys [:metrics_url, :logs_url, :traces_url, :token, :metrics_token, :logs_token] ++
                  [:traces_token]

    # How far back the recordings are listed.
    @listed 31 * 86_400.0

    @impl true
    def menu_link(_session, _capabilities), do: {:ok, "TimelessAcct"}

    @impl true
    def mount(_params, _session, socket) do
      {:ok, socket |> assign(said: nil, watch: nil) |> read()}
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
        do: {:noreply, assign(socket, watch: TimelessBeamAcct.Watch.read_moment(watch))},
        else: {:noreply, socket}
    end

    def handle_refresh(socket), do: {:noreply, read(socket)}

    @impl true
    def handle_event("key", %{"key" => key} = params, %{assigns: %{watch: %{} = watch}} = socket) do
      case Opened.key(key, params["shiftKey"] == true) do
        nil ->
          {:noreply, socket}

        pressed ->
          watch = Opened.pressed(watch, pressed)

          # q, or escape out of everything, is back to the recordings.
          if watch.state.quit,
            do: {:noreply, push_patch(socket, to: socket.assigns.here)},
            else: {:noreply, assign(socket, watch: watch)}
      end
    end

    def handle_event("key", _params, socket), do: {:noreply, socket}

    def handle_event("goto", %{"column" => column}, %{assigns: %{watch: %{} = watch}} = socket) do
      {:noreply, assign(socket, watch: Opened.go_to_column(watch, String.to_integer(column)))}
    end

    def handle_event("tab", %{"tab" => n}, %{assigns: %{watch: %{} = watch}} = socket) do
      {:noreply, assign(socket, watch: Opened.tab(watch, n))}
    end

    def handle_event("record", params, socket) do
      length = if params["length"] == "other", do: params["other"], else: params["length"]

      start_at =
        case params["start"] do
          "at" -> [start_at: params["start_at"]]
          _ -> []
        end

      opts =
        [stop_after: length, recorded_by: "LiveDashboard on #{node()}", sink: :http] ++
          start_at ++
          Keyword.take(configured(), @plane_keys) ++
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
        case call(socket, TimelessBeamAcct, :stop, []) do
          {:ok, :ok} -> "The recording was stopped."
          {:error, why} -> "It could not be stopped: #{why}"
          {:ok, other} -> "It could not be stopped: #{inspect(other)}"
        end

      {:noreply, socket |> assign(said: said) |> read()}
    end

    def handle_event("extend", %{"by" => by}, socket) do
      said =
        case call(socket, TimelessBeamAcct, :extend, [TimelessBeamAcct, by]) do
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

      {running, collecting, waiting} =
        case Live.status(%Live{node: node}) do
          {:ok, %{waiting: waiting}} -> {nil, true, waiting}
          {:ok, %{recording: %{} = recording}} -> {recording, true, nil}
          {:ok, _not_a_recording} -> {nil, true, nil}
          _ -> {nil, false, nil}
        end

      {recordings, error} =
        case planes() do
          nil ->
            {[],
             "Where the planes are is not configured: config :timeless_beam_acct, :dashboard, logs_url: ..."}

          {:error, why} ->
            {[], why}

          {:ok, planes} ->
            case Store.recordings(planes, now - @listed, now) do
              {:ok, recordings} -> {recordings, nil}
              {:error, why} -> {[], why}
            end
        end

      assign(socket,
        links: Map.new(recordings, &{&1.id, "?" <> URI.encode_query(recording: &1.id)}),
        node: node,
        now: now,
        running: running,
        collecting: collecting,
        waiting: waiting,
        recordings: recordings,
        error: error
      )
    end

    defp configured, do: Application.get_env(:timeless_beam_acct, :dashboard, [])

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
      <Opened.recording watch={@opened} back={@back} />
      """
    end

    def render(assigns) do
      ~H"""
      <div class="tba">
        <style>
          .tba table { width: 100%; font-variant-numeric: tabular-nums; }
          .tba th, .tba td { padding: 0.25rem 0.75rem; text-align: left; white-space: nowrap; }
          .tba .tba-banner { padding: 0.75rem 1rem; margin-bottom: 1rem; border-radius: 0.25rem; background: rgba(0, 128, 255, 0.08); }
          .tba .tba-bar { height: 0.4rem; background: rgba(0, 0, 0, 0.1); border-radius: 0.2rem; margin: 0.5rem 0; }
          .tba .tba-bar > div { height: 100%; background: #0a7; border-radius: 0.2rem; }
          .tba .tba-said { margin-bottom: 1rem; }
          .tba .tba-error { color: #c33; margin-bottom: 1rem; }
        </style>

        <div :if={@said} class="tba-said">{@said}</div>

        <div :if={@running} class="tba-banner">
          <strong>Recording {@node}</strong>,
          started {Clock.format(@running.started)}{if @running.by, do: " by #{@running.by}"},
          {Human.duration(@now - @running.started)} of {Human.duration(@running.stop_at - @running.started)};
          it ends by itself at {Clock.format(@running.stop_at)}.
          <div class="tba-bar"><div style={"width: #{progress(@running, @now)}%"}></div></div>
          <button phx-click="stop" data-confirm="Stop this recording now?">Stop</button>
          <button phx-click="extend" phx-value-by="1h">+1 hour</button>
        </div>

        <div :if={@waiting} class="tba-banner">
          <strong>{@node} is to be recorded</strong>
          from {Clock.format(@waiting.start_at)}, for {Human.duration(@waiting.stop_after)}{if @waiting.by,
            do: ", as asked by #{@waiting.by}"}. Until then it waits, and reads nothing.
          <div>
            <button phx-click="stop" data-confirm="Call this recording off?">Call it off</button>
          </div>
        </div>

        <p :if={!@running and @collecting and !@waiting}>
          A collector is running in {@node}, and is not a recording: it runs until it is
          stopped. It was started in code or by <code>attach</code>, without <code>stop_after</code>.
        </p>

        <form :if={!@running and !@collecting} phx-submit="record" class="tba-banner">
          <strong>Record {@node}</strong>
          <div>
            for
            <label :for={{value, label} <- lengths()}>
              <input type="radio" name="length" value={value} checked={value == "1h"} /> {label}
            </label>
            <label><input type="radio" name="length" value="other" /></label>
            <input type="text" name="other" placeholder="90m" size="5" />
          </div>
          <div>
            start
            <label><input type="radio" name="start" value="now" checked /> now</label>
            <label><input type="radio" name="start" value="at" /> at</label>
            <input type="text" name="start_at" placeholder="01:55" size="6" />
            <small>(the node's time; a time that has passed today is tomorrow)</small>
          </div>
          <div>
            <label>
              <input type="checkbox" name="processes" value="true" checked />
              a series for each notable process (more to look at, more to store)
            </label>
          </div>
          <div>
            <label>
              <input type="checkbox" name="failed_only" value="true" />
              a record only of processes that failed (less to store on a busy node)
            </label>
          </div>
          <p>
            A recording costs a node about 5% of one core where 65 processes end a second, and
            less where fewer do. It ends by itself; a day at most.
          </p>
          <button type="submit" data-confirm={"Record #{@node}?"}>Record</button>
        </form>

        <div :if={@error} class="tba-error">{@error}</div>

        <h5>Recordings</h5>
        <table :if={@recordings != []}>
          <thead>
            <tr><th>Started</th><th>Length</th><th>Node</th><th>Ended</th><th>By</th><th>Id</th></tr>
          </thead>
          <tbody>
            <tr :for={r <- @recordings}>
              <td>{Clock.format(r.started)}</td>
              <td>{length_of(r, @now)}</td>
              <td>{r.node}</td>
              <td>{how(r, @now)}</td>
              <td>{r.by}</td>
              <td><a href={@links[r.id]}><code>{String.slice(r.id, 0, 8)}</code></a></td>
            </tr>
          </tbody>
        </table>
        <p :if={@recordings == [] and !@error}>No recordings in the last 31 days.</p>
      </div>
      """
    end

    defp progress(recording, now) do
      length = max(recording.stop_at - recording.started, 1.0)
      Float.round(min(max((now - recording.started) / length, 0.0), 1.0) * 100, 1)
    end

    defp length_of(%{ended: ended, started: started}, _now) when is_number(ended),
      do: Human.duration(ended - started)

    defp length_of(%{stop_at: stop_at, started: started}, now) when stop_at > now,
      do: Human.duration(now - started) <> " so far"

    defp length_of(_recording, _now), do: "-"

    defp how(%{ended: ended, reason: "time"}, _now) when is_number(ended), do: "its time ran out"
    defp how(%{ended: ended, reason: "stopped"}, _now) when is_number(ended), do: "it was stopped"
    defp how(%{ended: ended}, _now) when is_number(ended), do: "what it ran in went first"

    defp how(%{stop_at: stop_at}, now) when stop_at > now,
      do: "running, until #{Clock.format(stop_at)}"

    defp how(_recording, _now), do: "its node ended first"
  end
end
