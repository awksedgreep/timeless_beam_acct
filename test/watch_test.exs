defmodule TimelessBeamAcct.WatchTest do
  # Not with the others: a collector hears of every process of the node.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias TimelessBeamAcct.{Clock, Watch}
  alias TimelessBeamAcct.Watch.{Data, Live, Memory, State, Store}
  alias TimelessBeamAcct.Watched

  @moduletag :capture_log

  defp collector(given \\ []) do
    name = :"watch_test_#{System.unique_integer([:positive])}"

    options =
      [
        name: name,
        sink: {:forward, to: self()},
        # Readings are asked for, and not waited for.
        interval: 3600,
        process_interval: 3600,
        min_age: 0,
        anomalies: false
      ] ++ given

    start_supervised!({TimelessBeamAcct, options})
    # Two readings: the second has rates.
    :ok = TimelessBeamAcct.tick(name)
    Process.sleep(20)
    :ok = TimelessBeamAcct.tick(name)
    name
  end

  defp screen(watch, size \\ {120, 40}) do
    {watch, lines} = Watch.screen(watch, size)
    {watch, Enum.join(lines, "\n")}
  end

  defp press(watch, keys) do
    keys =
      Enum.flat_map(List.wrap(keys), fn
        text when is_binary(text) -> for char <- String.graphemes(text), do: {:char, char}
        key -> [key]
      end)

    case Watch.pressed(watch, keys) do
      {watch, :moment} -> Watch.read_moment(watch)
      {watch, _changed} -> watch
    end
  end

  # A process that ends, and is accounted at the next reading.
  defp ended(name, fun) do
    {pid, ref} = spawn_monitor(fun)
    assert_receive {:DOWN, ^ref, _, _, _}, 5_000
    Process.sleep(20)
    :ok = TimelessBeamAcct.tick(name)
    pid
  end

  describe "what is watched" do
    test "is a node, or a store, and is said to be missing if it is neither" do
      assert {:error, why} = Watch.new([])
      assert why =~ "Which node, or which store?"

      assert {:error, why} = Watch.new(node: node(), name: :no_such_collector)
      assert why =~ "has no collector running"
      assert why =~ "mix timeless_beam_acct.attach #{node()}"

      assert {:error, why} = Watch.new(metrics_url: "http://127.0.0.1:1", timeout: 500)
      assert why =~ "http://127.0.0.1:1: connection refused"
    end

    test "is refused what is not understood" do
      store = %Watched.Store{}
      assert {:error, why} = Watch.new(store: store, view: :units)
      assert why =~ "--view is units"
      assert {:error, why} = Watch.new(store: store, refresh: 0)
      assert why =~ "--refresh is a number of seconds"
      assert {:error, why} = Watch.new(store: store, at: "yesterday")
      assert why =~ "yesterday"
      assert {:error, why} = Watch.run(store: store, print: "30x5")
      assert why =~ "\"30x5\" is not a size"
      assert {:error, _} = Watch.run(store: store, print: "wide")
    end

    test "begins at the moment and in the view it was told" do
      assert {:ok, watch} = Watch.new(store: %Watched.Store{}, at: "1000", view: :exits)
      assert watch.state.at == 1000.0
      assert watch.state.tab == :exits
      assert {:ok, watch} = Watch.new(store: %Watched.Store{})
      assert State.live?(watch.state)
      assert watch.state.tab == :groups
    end
  end

  describe "a node whose collector writes to nothing that can be asked" do
    test "is watched as it is now, with what its collector has in memory" do
      name = collector()
      assert {:ok, watch} = Watch.new(node: node(), name: name)
      assert %Memory{live: %Live{name: ^name}} = watch.store
      assert watch.state.message =~ "Only now: the collector writes to nothing that can be asked"
      # The collector says how often it reads.
      watch = Watch.read_moment(watch)
      assert watch.state.step == 3600.0

      refute Data.empty?(watch.snapshot)
      assert watch.snapshot.vm.processes > 10
      assert is_number(watch.snapshot.vm.memory)
      # The collector is a group of one, under the name it was started under.
      collector = Enum.find(watch.snapshot.groups, &String.ends_with?(&1.name, ".Collector"))
      assert %{processes: 1} = collector
      assert is_number(collector.work)
      # Every process the collector has, and not only those with series.
      assert length(watch.snapshot.processes) > 10
      assert Enum.any?(watch.snapshot.apps, &(&1.name == "kernel"))

      {watch, text} = screen(watch)
      assert text =~ "timeless-beam-acct #{node()}"
      assert text =~ "● LIVE"
      assert text =~ ~r/run queue \d+   schedulers /
      assert text =~ collector.name
      assert text =~ "Only now: the collector writes to nothing"
      # There is no other moment to go to.
      assert {_watch, :nothing} = Watch.pressed(watch, [:left])

      assert {watch, :view} =
               Watch.pressed(watch, String.graphemes("t-5m") |> Enum.map(&{:char, &1}))

      assert {watch, _} = Watch.pressed(watch, [:enter])
      assert watch.state.message == "There is nothing stored to go to."
    end

    test "has its processes, and what is known of one that is running" do
      name = collector()
      {:ok, watch} = Watch.new(node: node(), name: name, view: :processes)
      writer = Atom.to_string(Module.concat(name, :Writer))
      watch = watch |> Watch.read_moment() |> press("/" <> writer) |> press(:enter)

      {watch, text} = screen(watch)
      assert text =~ ~r/PROCESS\s+PID\s+APP/
      assert text =~ "only " <> writer
      assert [%{name: ^writer}] = State.processes(watch.state, watch.snapshot)
      assert text =~ "The collector writes to nothing that can be asked."

      {_watch, text} = watch |> press(:enter) |> screen()
      assert text =~ "any key"
      assert text =~ ~r/is\s+#{Regex.escape(writer)}/
      assert text =~ ~r/running\s+:gen_server.loop\/\d/
      assert text =~ ~r/status\s+waiting/
      assert text =~ ~r/ended\s+It is still running\./
    end

    @tag skip:
           if(TimelessBeamAcct.Tracer.available?(),
             do: false,
             else: "this VM has no trace sessions"
           )
    test "has the processes that ended, and how" do
      name = collector()

      ended(name, fn -> exit(:normal) end)
      pid = ended(name, fn -> exit({:timeout, :waiting}) end)

      {:ok, watch} = Watch.new(node: node(), name: name, view: :exits)
      watch = Watch.read_moment(watch)
      assert length(watch.detail.exits) >= 2

      watch = watch |> press("/timeout") |> press(:enter)
      {watch, text} = screen(watch)
      assert [%{status: "timeout", pid: shown}] = watch.detail.exits
      assert shown == inspect(pid) |> String.replace("#PID", "")
      assert text =~ ~r/#{Regex.escape(shown)} timeout/

      # What went wrong is marked, of what is in memory too.
      assert Enum.any?(watch.detail.incidents, &(&1.at == hd(watch.detail.exits).at)) or
               hd(watch.detail.exits).level not in ["error", "warning"]

      {watch, text} = watch |> press(:enter) |> screen()
      assert text =~ ~r/ended\s+.*: exited timeout, after/
      assert text =~ ~r/reason\s+\{:timeout, :waiting\}/
      # Its moment is not one that can be gone to: nothing is stored.
      watch = press(press(watch, :enter), "m")
      assert watch.state.message == "There is nothing stored to go to."
    end

    test "has the jobs that ran" do
      name = collector()

      ended(name, fn ->
        task = Task.async(fn -> :ok end)
        Task.await(task)
      end)

      {:ok, watch} = Watch.new(node: node(), name: name, view: :jobs)
      watch = Watch.read_moment(watch)

      if TimelessBeamAcct.Tracer.available?() do
        assert [%{processes: 2, failed: 0, tree: [_root, child]} | _] = watch.detail.jobs
        assert child =~ "└─ "
        {_watch, text} = screen(watch)
        assert text =~ "what it was"
        assert text =~ "└─ "
      end
    end

    test "is drawn once, as text, when that is asked for" do
      name = collector()

      printed =
        capture_io(fn -> assert :ok = Watch.run(node: node(), name: name, print: "100x20") end)

      lines = String.split(printed, "\n", trim: true)
      assert length(lines) == 20
      assert hd(lines) =~ "┌ timeless-beam-acct #{node()}"
      assert Enum.all?(lines, &(String.length(&1) <= 100))
    end

    test "is asked again when its collector has read again, and not before" do
      name = collector()
      {:ok, watch} = Watch.new(node: node(), name: name)
      watch = Watch.read_moment(watch)
      assert {{stamp, [most: 300]}, {:ok, answered}} = watch.asked

      # Nothing has been read since: what it answered is what there is.
      again = Watch.read_moment(watch)
      assert again.asked == watch.asked

      Process.sleep(1100)
      :ok = TimelessBeamAcct.tick(name)
      again = Watch.read_moment(watch)
      assert {{later, [most: 300]}, {:ok, newer}} = again.asked
      assert later != stamp
      assert newer.at > answered.at

      # Into a group, it is asked for the processes of that group.
      group = hd(State.groups(again.state, again.snapshot)).name
      into = again |> press(:enter) |> Watch.read_moment()
      assert {{^later, [most: 300, group: ^group]}, {:ok, of_group}} = into.asked
      assert Enum.all?(of_group.processes, &(&1.group == group))
      assert of_group.processes != []
    end

    test "with a collector that keeps no reading, has its processes and no more" do
      name = collector(history: 0)
      {:ok, watch} = Watch.new(node: node(), name: name)
      watch = Watch.read_moment(watch)
      assert watch.snapshot.groups == []
      assert length(watch.snapshot.processes) > 10
    end
  end

  describe "a node and a store" do
    defp stored(more \\ []) do
      now = Clock.now()

      struct!(
        %Watched.Store{
          range: {now - 7200, now - 5},
          series: Data.series(Watched.samples()),
          history: [{now - 20, 1.0}, {now - 10, 2.0}],
          timeline: {[{now - 60, 5.0}, {now - 50, 9.5}], 10.0},
          incidents: [%{at: now - 55, error: true}],
          to: self()
        },
        more
      )
    end

    defp exit_at(at, fields) do
      Store.exit(
        at,
        fields[:level] || "info",
        Map.merge(
          %{
            "kind" => "exit",
            "service" => "MyApp.Worker",
            "pid" => "<0.700.0>",
            "app" => "my_app",
            "status" => "normal",
            "elapsed_seconds" => 1.5
          },
          fields[:fields] || %{}
        )
      )
    end

    test "now is the node's, and its history the store's" do
      name = collector()
      {:ok, watch} = Watch.new(node: node(), name: name, store: stored())
      watch = Watch.read_moment(watch)

      # Now was not asked of the store.
      refute_received {:asked, {:at, _, _, _}}
      assert Enum.any?(watch.snapshot.groups, &String.ends_with?(&1.name, ".Collector"))
      assert watch.state.message == nil

      # The history of the picked row was.
      picked = hd(State.groups(watch.state, watch.snapshot)).name
      assert_received {:asked, {:history, "beam_group_work_pct", "group", ^picked, from, to}}
      assert_in_delta to - from, 600.0, 0.001

      assert watch.detail.history == [{to - 15, 1.0}, {to - 5, 2.0}] or
               length(watch.detail.history) == 2

      {_watch, text} = screen(watch)
      assert text =~ "#{picked} work, the 10m00s before"
      assert text =~ "peak 2.0%"
      assert text =~ "schedulers over 1h00m, up to 9.5%"
      assert text =~ "!"
    end

    test "another moment is the store's" do
      name = collector()
      store = stored()
      {first, last} = store.range
      {:ok, watch} = Watch.new(node: node(), name: name, store: store)
      watch = Watch.read_moment(watch)

      # Back from now is the last moment stored, at the collector's pace.
      watch = press(watch, :left)
      at = watch.state.at
      assert at <= last and at > last - 3600
      assert_received {:asked, {:at, ^at, within, [:vm, :groups, :apps]}}
      assert within == 3 * 3600.0

      assert Enum.map(watch.snapshot.groups, & &1.name) == [
               "MyApp.Repo",
               "MyApp.Worker",
               "New.Thing"
             ]

      assert [%{name: "MyApp.Repo"}, %{name: "worker_7"}] = watch.snapshot.processes

      {watch, text} = screen(watch)
      assert text =~ "◀ " <> Clock.format(at)
      assert text =~ " ago "
      refute text =~ "LIVE"

      watch = press(watch, :home)
      assert watch.state.at == first / 1
      watch = press(watch, "l")
      assert State.live?(watch.state)
      assert Enum.any?(watch.snapshot.groups, &String.ends_with?(&1.name, ".Collector"))
    end

    test "a recording is opened by its id, at its end, with all of it on the timeline" do
      now = Clock.now()

      recording = %{
        id: "abc123",
        node: "app@ohm",
        host: "ohm",
        started: now - 5 * 3600,
        stop_at: now - 3600,
        ended: now - 3600,
        reason: "time",
        by: nil
      }

      plane =
        start_supervised!(
          {TimelessBeamAcct.TestPlane,
           answer: fn _ ->
             fields = %{
               "kind" => "recording",
               "service" => "recording",
               "recording" => recording.id,
               "node" => recording.node,
               "started" => recording.started,
               "stop_at" => recording.stop_at
             }

             time = fn at -> at |> trunc() |> DateTime.from_unix!() |> DateTime.to_iso8601() end

             body =
               [
                 Map.merge(fields, %{
                   "status" => "ended",
                   "reason" => "time",
                   "_time" => time.(recording.ended)
                 }),
                 Map.merge(fields, %{"status" => "started", "_time" => time.(recording.started)})
               ]
               |> Enum.map_join("\n", &JSON.encode!/1)

             {200, body}
           end}
        )

      url = TimelessBeamAcct.TestPlane.url(plane)

      # Found by the beginning of its id.
      assert {:error, why} =
               Watch.new(
                 logs_url: url,
                 metrics_url: "http://127.0.0.1:1",
                 recording: "abc",
                 timeout: 500
               )

      # It is found; then the metrics plane, which is not there, is reached for.
      assert why =~ "http://127.0.0.1:1"

      assert {:error, why} = Watch.new(logs_url: url, recording: "zzz")
      assert why =~ "No recording zzz"
    end

    test "a recording whose node ended first is opened where what it wrote ends" do
      now = Clock.now()
      {started, stop_at, died} = {now - 5 * 3600, now - 3600, trunc(now - 3 * 3600)}
      time = fn at -> at |> trunc() |> DateTime.from_unix!() |> DateTime.to_iso8601() end

      started_only =
        JSON.encode!(%{
          "kind" => "recording",
          "service" => "recording",
          "status" => "started",
          "recording" => "def456",
          "node" => "app@ohm",
          "started" => started,
          "stop_at" => stop_at,
          "_time" => time.(started)
        })

      # Readings every ten seconds until it died; five-minute parts of them
      # over its stretch, stamped as PromQL stamps them, at each one's end.
      readings = Enum.to_list(trunc(started)..died//10)
      parts = for at <- trunc(started)..died//300, do: [at + 300, "500"]

      matrix = fn values ->
        %{
          "status" => "success",
          "data" => %{"result" => [%{"metric" => %{}, "values" => values}]}
        }
      end

      plane =
        start_supervised!({TimelessBeamAcct.TestPlane,
         answer: fn %{path: path} ->
           query =
             path |> URI.parse() |> Map.get(:query, "") |> to_string() |> URI.decode_query()

           cond do
             path =~ "/select/logsql" ->
               {200, started_only}

             path =~ "/api/v1/query_range" ->
               {200, JSON.encode!(matrix.(parts))}

             # A range selector: the readings in the seconds up to then.
             path =~ "/api/v1/query" ->
               [_, seconds] = Regex.run(~r/\[(\d+)s\]$/, query["query"])
               to = String.to_integer(query["time"])
               from = to - String.to_integer(seconds)
               values = for at <- readings, at > from, at <= to, do: [at, "500"]
               {200, JSON.encode!(matrix.(values))}

             path =~ "/label/node/values" ->
               {200, JSON.encode!(%{"data" => ["app@ohm"]})}

             true ->
               {200, JSON.encode!(%{"data" => []})}
           end
         end})

      url = TimelessBeamAcct.TestPlane.url(plane)

      assert {:ok, watch} =
               Watch.new(logs_url: url, metrics_url: url, traces_url: url, recording: "def")

      # Not at its stop_at, where there is nothing: at its last reading.
      assert watch.state.at == died / 1
      assert {^started, ended} = watch.state.stretch
      assert ended == died / 1
    end

    test "a group is gone into, and stays gone into through time" do
      {:ok, watch} = Watch.new(store: stored(), at: "-10m")
      watch = Watch.read_moment(watch)
      assert_received {:asked, {:at, _, 30.0, [:vm, :groups, :apps]}}

      watch = watch |> press("j") |> press(:enter)
      assert watch.state.within == {:group, "MyApp.Worker"}
      assert watch.state.tab == :processes

      assert_received {:asked,
                       {:history, "beam_proc_work_pct", "proc", "worker_7<0.700.0>", _, _}}

      {watch, text} = screen(watch)
      assert text =~ "in MyApp.Worker"
      refute text =~ "MyApp.Repo<"

      watch = press(watch, ",")
      assert watch.state.within == {:group, "MyApp.Worker"}
      watch = press(watch, :esc)
      assert watch.state.within == nil
      assert watch.state.tab == :groups

      # An application is gone into in the same way.
      watch = watch |> press("a") |> press(:enter)
      assert watch.state.within == {:app, "my_app"}
      assert length(State.processes(watch.state, watch.snapshot)) == 2
    end

    test "with no node to ask, now is the last moment stored" do
      store = stored()
      {_first, last} = store.range
      {:ok, watch} = Watch.new(store: store)
      watch = Watch.read_moment(watch)
      assert State.live?(watch.state)
      assert_received {:asked, {:at, ^last, 30.0, _tiers}}
      assert watch.snapshot.at == last
      assert watch.state.step == 10.0
      assert length(watch.snapshot.groups) == 3

      # A process that is not known to have ended, and cannot be asked of.
      watch = watch |> press("2") |> press(:enter)
      assert {"MyApp.Repo<0.512.0>", lines} = watch.detail.inspected
      assert {"is", "MyApp.Repo"} in lines
      assert {"ended", "Nothing says that it has, and nothing of it is known but this."} in lines
    end

    test "a process that has ended since is known by its record" do
      now = Clock.now()

      record =
        exit_at(now - 300,
          level: "warning",
          fields: %{
            "status" => "killed",
            "reason" => ":killed",
            "parent" => "<0.10.0>",
            "parent_name" => "MyApp.Supervisor",
            "path" => "MyApp.Worker.init/1",
            "name" => "worker_7",
            "started" => now - 400,
            "reductions" => 48_100,
            "peak_memory_bytes" => 2_400_000,
            "figures_age_seconds" => 4.0,
            "trace_id" => "abc123"
          }
        )

      {:ok, watch} = Watch.new(store: stored(exits: [record]), at: "-10m", view: :processes)
      watch = watch |> Watch.read_moment() |> press("j") |> press(:enter)

      assert {"worker_7<0.700.0>", lines} = watch.detail.inspected
      assert {"was", "MyApp.Worker"} in lines
      assert {"named", "worker_7"} in lines
      assert {"started with", "MyApp.Worker.init/1"} in lines
      assert {"started by", "MyApp.Supervisor<0.10.0>"} in lines
      assert {"ended", "#{Clock.format(now - 300)}: was killed, after 1.5s"} in lines
      assert {"reductions", "48.1k"} in lines
      assert {"peak memory", "2.3 MiB"} in lines
      assert {"trace", "abc123"} in lines

      assert Enum.any?(
               lines,
               &match?({"note", "Its figures are those of the last sweep" <> _}, &1)
             )

      {_watch, text} = screen(watch)
      assert text =~ "was killed, after 1.5s"
    end

    test "exits are looked for as far back as the timeline shows, when something is looked for" do
      now = Clock.now()
      exits = [exit_at(now - 100, []), exit_at(now - 200, fields: %{"status" => "killed"})]
      {:ok, watch} = Watch.new(store: stored(exits: exits), view: :exits)
      watch = Watch.read_moment(watch)
      assert_received {:asked, {:exits, %{span: 900.0, limit: 200}}}
      assert length(watch.detail.exits) == 2

      watch = watch |> press("/killed") |> press(:enter)
      assert_received {:asked, {:exits, %{span: 3600.0}}}
      assert [%{status: "killed", at: at}] = watch.detail.exits

      # Its moment is gone to, as near as the store sampled one.
      watch = press(watch, "m")
      assert watch.state.at == Float.floor(at / 10) * 10
      assert State.selected(watch.state) == 0

      watch = press(watch, "1") |> press("m")
      assert watch.state.message == "An exit or a job has a moment to go to: views 3 and 4."
    end

    test "jobs are the store's, and their moments are gone to" do
      now = Clock.now()

      job = %{
        started: now - 120,
        duration: 2.5,
        reductions: nil,
        processes: 2,
        failed: 0,
        app: "my_app",
        name: "MyApp.Batch",
        tree: ["MyApp.Batch  2.5s", "└─ MyApp.Worker  1.0s"],
        running: false
      }

      {:ok, watch} = Watch.new(store: stored(jobs: [job]), view: :jobs)
      watch = Watch.read_moment(watch)
      assert_received {:asked, {:jobs, %{span: 900.0}}}
      {watch, text} = screen(watch)
      assert text =~ "MyApp.Batch"
      assert text =~ "└─ MyApp.Worker  1.0s"

      watch = press(watch, "m")
      assert watch.state.at == Float.floor((now - 120) / 10) * 10
      # Opening a job is nothing: it is open already.
      assert press(watch, :enter).state.inspecting == false
    end

    test "a store that will not answer is said, and the screen is still drawn" do
      {:ok, watch} = Watch.new(store: stored(error: "the store is away"), at: "-10m")
      {watch, text} = watch |> Watch.read_moment() |> screen()
      assert text =~ "the store is away"
      assert Data.empty?(watch.snapshot)

      watch = press(watch, "4")
      assert watch.detail.error == "the store is away"
    end

    test "the timeline is read again when the stretch it shows is another" do
      {:ok, watch} = Watch.new(store: stored(), at: "-10m")
      watch = Watch.read_moment(watch)
      assert_received {:asked, {:timeline, from, to}}
      assert_in_delta to - from, 3600.0, 0.001

      # The same stretch is not read twice, of a moment that does not change.
      watch = press(watch, :left)
      refute_received {:asked, {:timeline, _, _}}

      watch = press(watch, "-")
      assert_received {:asked, {:timeline, from, to}}
      assert_in_delta to - from, 6 * 3600.0, 0.001
      {_watch, text} = screen(watch)
      assert text =~ "schedulers over 6h00m"
    end
  end
end
