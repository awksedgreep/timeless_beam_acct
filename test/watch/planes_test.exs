defmodule TimelessBeamAcct.Watch.PlanesTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.TestPlane
  alias TimelessBeamAcct.Watch.{Data, Planes, Store}

  @node "app@ohm"

  # A plane that answers each question with what it was told to, by the
  # path that was asked for. The question is kept.
  defp plane(answers) do
    plane = start_supervised!({TestPlane, []}, id: make_ref())

    TestPlane.answer(plane, fn request ->
      %URI{path: path, query: query} = URI.parse(request.path)
      asked = URI.decode_query(query || "")

      case Enum.find_value(answers, fn {at, answer} -> if at == path, do: answer end) do
        nil -> {422, ~s({"error":"unsupported_capability","reason":"unsupported_route"})}
        answer when is_function(answer) -> answered(answer.(asked))
        answer -> answered(answer)
      end
    end)

    plane
  end

  defp answered({status, body}), do: {status, body}
  defp answered(body) when is_binary(body), do: {200, body}
  defp answered(body), do: {200, JSON.encode!(body)}

  defp store(plane, more \\ []) do
    url = TestPlane.url(plane)

    {:ok, store} =
      Planes.new([metrics_url: url, logs_url: url, traces_url: url, node: @node] ++ more)

    store
  end

  # What was asked of a path, as its parameters.
  defp asked(plane, path) do
    for request <- TestPlane.requests(plane),
        %URI{path: ^path, query: query} <- [URI.parse(request.path)],
        do: URI.decode_query(query || "")
  end

  defp lines(rows), do: Enum.map_join(rows, "\n", &JSON.encode!/1)

  defp record(at, fields) do
    Map.merge(
      %{
        "_msg" => "it ended",
        "_time" => at |> trunc() |> DateTime.from_unix!() |> DateTime.to_iso8601(),
        "level" => "info",
        "kind" => "exit",
        "node" => @node,
        "host" => "ohm",
        "service" => "MyApp.Worker",
        "pid" => "<0.1.0>",
        "app" => "my_app",
        "status" => "normal",
        "elapsed_seconds" => 0.25
      },
      fields
    )
  end

  defp span(trace, id, parent, name, start, more \\ %{}) do
    Map.merge(
      %{
        "trace_id" => String.duplicate(trace, 16),
        "span_id" => String.duplicate(id, 8),
        "parent_span_id" => parent && String.duplicate(parent, 8),
        "name" => name,
        "status" => "ok",
        "status_message" => "exited normal",
        "start_time" => start * 1_000_000_000,
        "duration_ns" => 2_000_000_000,
        "attributes" => %{"process.reductions" => 500},
        "resource" => %{"service.name" => "my_app", "service.instance.id" => @node}
      },
      more
    )
  end

  describe "which store" do
    test "is where it was said to be, and nowhere that was not said" do
      assert {:ok, store} = Planes.new(metrics_url: "http://127.0.0.1:1/")
      assert store.metrics == "http://127.0.0.1:1"
      assert store.logs == nil and store.traces == nil

      # A plane that was not said is not read, and says so.
      assert {:error, why} =
               Store.exits(store, %{until: 10.0, span: 5.0, limit: 1}, fn _ -> true end)

      assert why == "Where the logs plane is was not said: --logs-url."

      assert {:error, why} =
               Store.jobs(store, %{until: 10.0, span: 5.0, limit: 1}, 80, fn _ -> true end)

      assert why =~ "--traces-url"

      # Unless it is where a collector writes when it is told nothing.
      assert {:ok, store} = Planes.new(defaults: true, logs_url: "http://logs:1")
      assert store.metrics == "http://127.0.0.1:8428"
      assert store.logs == "http://logs:1"
      assert store.traces == "http://127.0.0.1:10428"

      assert {:error, why} = Planes.new(metric_url: "http://127.0.0.1:1")
      assert why =~ ":metric_url is not something a store is told"
    end

    test "the node is the only one there is, unless it was said" do
      plane = plane([{"/api/v1/label/node/values", %{"status" => "success", "data" => [@node]}}])
      {:ok, store} = Planes.new(metrics_url: TestPlane.url(plane))

      assert {:ok, %Planes{node: @node}} = Planes.reach(store)
      assert [%{"metric" => "beam_vm_processes"}] = asked(plane, "/api/v1/label/node/values")

      assert {:ok, %Planes{node: "other@ohm"}} = Planes.reach(%{store | node: "other@ohm"})
    end

    test "several nodes are said, and none is chosen" do
      plane =
        plane([{"/api/v1/label/node/values", %{"status" => "success", "data" => ["a@x", "b@x"]}}])

      {:ok, store} = Planes.new(metrics_url: TestPlane.url(plane))
      assert {:error, why} = Planes.reach(store)
      assert why =~ "has these nodes, and one is to be said with --node: a@x, b@x"
    end

    test "a store with nothing a collector wrote, or none, is said" do
      plane = plane([{"/api/v1/label/node/values", %{"status" => "success", "data" => []}}])
      {:ok, store} = Planes.new(metrics_url: TestPlane.url(plane))
      assert {:error, why} = Planes.reach(store)
      assert why =~ "has nothing a collector wrote"

      TestPlane.stop_listening(plane)
      assert {:error, why} = Planes.reach(store)
      assert why =~ "connection refused"
      assert {:error, _} = Planes.reach(%{store | node: @node})
    end

    test "a plane that is busy is asked again, once" do
      # How many times it was asked, and how many busy answers it has left.
      counter = :counters.new(2, [])
      :counters.put(counter, 2, 1)

      plane =
        plane([
          {"/api/v1/label/node/values",
           fn _asked ->
             :counters.add(counter, 1, 1)

             if :counters.get(counter, 2) > 0 do
               :counters.sub(counter, 2, 1)
               {503, ~s({"error":"storage is temporarily busy; retry request"})}
             else
               %{"status" => "success", "data" => [@node]}
             end
           end}
        ])

      {:ok, store} = Planes.new(metrics_url: TestPlane.url(plane))
      assert {:ok, %Planes{node: @node}} = Planes.reach(store)
      assert :counters.get(counter, 1) == 2

      # Busy twice is busy.
      :counters.put(counter, 1, 0)
      :counters.put(counter, 2, 2)
      assert {:error, why} = Planes.reach(store)
      assert why =~ "answered 503: storage is temporarily busy"
      assert :counters.get(counter, 1) == 2
    end

    test "a token is sent to the plane it is for" do
      plane = plane([{"/api/v1/label/node/values", %{"status" => "success", "data" => [@node]}}])
      url = TestPlane.url(plane)

      {:ok, store} = Planes.new(metrics_url: url, token: "all", logs_token: "logs", logs_url: url)
      assert store.tokens == %{metrics: "all", logs: "logs", traces: "all"}
      {:ok, _} = Planes.reach(store)
      Store.incidents(store, 0.0, 10.0, 10)

      assert ["Bearer all", "Bearer logs", "Bearer logs"] =
               for(request <- TestPlane.requests(plane), do: request.headers["authorization"])
    end
  end

  describe "the moments it holds" do
    test "are from the first sample of the node to the last" do
      plane =
        plane([
          {"/api/v1/query",
           %{"labels" => %{"node" => @node}, "timestamp" => 5000, "value" => 512.0}},
          {"/select/metrics/stats", %{"oldest_timestamp_seconds" => 10}},
          {"/api/v1/query_range", %{"series" => [%{"data" => [[60, 0], [960, 3], [1020, 6]]}]}},
          {"/api/v1/export",
           lines([%{"timestamps" => [1_000_000, 1_010_000], "values" => [510.0, 511.0]}])}
        ])

      store = store(plane, host: "ohm")
      assert {{1000.0, 5000.0}, store} = Store.range(store)

      # Of this node on this host, and no other.
      assert [%{"metric" => "beam_vm_processes", "node" => @node, "host" => "ohm"}] =
               asked(plane, "/api/v1/query")

      assert [%{"aggregate" => "count", "start" => start, "end" => "5000", "step" => "60"}] =
               asked(plane, "/api/v1/query_range")

      assert String.to_integer(start) < 10
      # The part of the stretch the first sample is in is what is read.
      assert [%{"start" => "960", "end" => "1020"}] = asked(plane, "/api/v1/export")

      # The first is not looked for again while it is fresh.
      TestPlane.clear(plane)
      assert {{1000.0, 5000.0}, _store} = Store.range(store)
      assert ["/api/v1/query"] = for(r <- TestPlane.requests(plane), do: URI.parse(r.path).path)
    end

    test "are none, of a store with no sample of the node" do
      plane = plane([{"/api/v1/query", %{"data" => []}}])
      assert {nil, _store} = Store.range(store(plane))

      TestPlane.stop_listening(plane)
      assert {nil, _store} = Store.range(store(plane))
    end

    test "are up to the latest of several series" do
      plane =
        plane([
          {"/api/v1/query",
           %{
             "data" => [
               %{"timestamp" => 4000, "value" => 1.0},
               %{"timestamp" => 4500, "value" => 1.0}
             ]
           }},
          {"/select/metrics/stats", {500, "no"}},
          {"/api/v1/query_range", {500, "no"}}
        ])

      # Where the first cannot be found out, there is the last.
      assert {{4500.0, 4500.0}, _store} = Store.range(store(plane))
    end
  end

  describe "a moment" do
    test "is every series of the node, as of then" do
      result = [
        %{
          "metric" => %{"__name__" => "beam_vm_run_queue", "host" => "ohm", "node" => @node},
          "value" => [5000, "2"]
        },
        %{
          "metric" => %{"__name__" => "beam_group_processes", "group" => "A", "node" => @node},
          "value" => [5000, "3.5"]
        },
        # What is not a figure is not a sample.
        %{
          "metric" => %{"__name__" => "beam_group_work_pct", "group" => "A"},
          "value" => [5000, "NaN"]
        }
      ]

      # A metric at a time, by name: each is answered with its series.
      plane =
        plane([
          {"/api/v1/query",
           fn %{"query" => query} ->
             [name | _] = String.split(query, "{")
             answer = Enum.filter(result, &(&1["metric"]["__name__"] == name))
             %{"status" => "success", "data" => %{"resultType" => "vector", "result" => answer}}
           end}
        ])

      assert {:ok, series} =
               Store.at(store(plane, host: ~s(o"hm)), 5000.9, 30.0, [
                 :vm,
                 :groups,
                 :apps,
                 :processes
               ])

      assert series == %{
               "beam_vm_run_queue" => [{%{}, 2.0}],
               "beam_group_processes" => [{%{"group" => "A"}, 3.5}]
             }

      assert %Data{vm: %{run_queue: 2.0}, groups: [%{name: "A"}]} = Data.read(5000.0, series)

      queries = asked(plane, "/api/v1/query")
      assert length(queries) == length(Data.metrics())

      # Of some tiers only, only their metrics are asked for.
      TestPlane.clear(plane)

      assert {:ok, %{"beam_vm_run_queue" => _} = few} =
               Store.at(store(plane), 5000.0, 30.0, [:vm])

      refute Map.has_key?(few, "beam_group_processes")
      assert length(asked(plane, "/api/v1/query")) == length(Data.metrics([:vm]))
      TestPlane.clear(plane)
      assert Enum.all?(queries, &(&1["time"] == "5000" and &1["lookback_delta"] == "30s"))

      names = for %{"query" => query} <- queries, do: query |> String.split("{") |> hd()
      assert Enum.sort(names) == Enum.sort(Data.metrics())

      assert Enum.all?(queries, fn %{"query" => query} ->
               String.ends_with?(query, ~S[{node="app@ohm",host="o\"hm"}])
             end)
    end

    test "that the plane will not answer for says what the plane said" do
      plane =
        plane([
          {"/api/v1/query",
           {422, ~s({"error":"query raw frame: work point limit exceeded","status":"error"})}}
        ])

      assert {:error, why} = Store.at(store(plane), 5000.0, 30.0, [:vm])
      assert why =~ "answered 422: query raw frame: work point limit exceeded"

      plane = plane([{"/api/v1/query", "not json"}])
      assert {:error, why} = Store.at(store(plane), 5000.0, 30.0, [:vm])
      assert why =~ "answered what is not the series of a moment"
    end
  end

  describe "a series over a stretch of time" do
    test "is its samples, in order" do
      plane =
        plane([
          {"/api/v1/export",
           lines([
             %{"timestamps" => [110_000, 100_000, 120_000], "values" => [2.0, 1.0, nil]}
           ])}
        ])

      store = store(plane)

      assert Store.history(store, "beam_group_work_pct", "group", "A", 90.5, 120.2) ==
               [{100.0, 1.0}, {110.0, 2.0}]

      assert [%{"metric" => "beam_group_work_pct", "group" => "A", "node" => @node} = asked] =
               asked(plane, "/api/v1/export")

      assert %{"start" => "90", "end" => "121"} = asked

      TestPlane.stop_listening(plane)
      assert Store.history(store, "beam_group_work_pct", "group", "A", 90.0, 120.0) == []
    end

    test "says how far apart the samples are" do
      every = fn seconds ->
        lines([
          %{
            "timestamps" => for(n <- 0..9, do: (1000 + n * seconds) * 1000),
            "values" => List.duplicate(1.0, 10)
          }
        ])
      end

      plane =
        plane([
          {"/api/v1/export",
           fn
             %{"metric" => "beam_vm_processes"} -> every.(10)
             %{"metric" => "beam_acct_processes"} -> every.(30)
           end}
        ])

      assert Store.spacing(store(plane), 2000.0) == {10.0, 30.0}
      assert Store.spacing(store(plane([{"/api/v1/export", ""}])), 2000.0) == {nil, nil}
    end
  end

  describe "the timeline" do
    test "of hours is the samples, and of days what is highest in each part of them" do
      plane =
        plane([
          {"/api/v1/export",
           fn
             %{"metric" => "beam_vm_scheduler_util_pct"} ->
               lines([%{"timestamps" => [1_000_000, 1_010_000], "values" => [5.0, 7.0]}])

             _ ->
               ""
           end},
          {"/api/v1/query_range", %{"series" => [%{"data" => [[600, 40.0], [900, 60.5]]}]}}
        ])

      store = store(plane)
      assert Store.timeline(store, 0.0, 3600.0) == {[{1000.0, 5.0}, {1010.0, 7.0}], 10.0}
      assert [] = asked(plane, "/api/v1/query_range")

      assert Store.timeline(store, 0.0, 6 * 3600.0) == {[{600.0, 40.0}, {900.0, 60.5}], 300.0}

      assert [%{"scheduler" => "all", "step" => "300", "aggregate" => "max", "node" => @node}] =
               asked(plane, "/api/v1/query_range")

      assert {_points, 3600.0} = Store.timeline(store, 0.0, 7 * 86_400.0)
    end

    test "of days is the samples, of a store too young to have more" do
      plane =
        plane([
          {"/api/v1/export",
           lines([
             %{"timestamps" => [1_000_000, 1_010_000, 1_020_000], "values" => [5.0, 7.0, 6.0]}
           ])},
          {"/api/v1/query_range", %{"series" => []}}
        ])

      assert {[{1000.0, 5.0}, _, _], 10.0} = Store.timeline(store(plane), 0.0, 6 * 3600.0)
    end
  end

  describe "what ended" do
    test "badly is marked: by raising, and by being killed" do
      plane =
        plane([
          {"/select/logsql/query",
           fn
             %{"level" => "error"} ->
               lines([
                 record(130.0, %{"level" => "error"}),
                 # Of another node.
                 record(131.0, %{"level" => "error", "node" => "other@ohm"})
               ])

             %{"level" => "warning"} ->
               lines([
                 record(105.0, %{"level" => "warning"}),
                 # What the VM remarked on is not a process that ended.
                 record(106.0, %{"level" => "warning", "kind" => "large_heap"})
               ])
           end}
        ])

      store = store(plane, host: "ohm")

      assert {[%{at: 105.0, error: false}, %{at: 130.0, error: true}], ^store} =
               Store.incidents(store, 100.0, 200.0, 10)

      assert [%{"start" => "100", "end" => "200", "host" => "ohm"}, _] =
               asked(plane, "/select/logsql/query")
    end

    test "badly, further back than are read at once, is asked about a part at a time" do
      # Errors every second from 100 to 200; kills at 105 and 150.
      plane =
        plane([
          {"/select/logsql/query",
           fn %{"level" => level, "start" => start, "end" => stop, "limit" => limit} ->
             {start, stop, limit} =
               {String.to_integer(start), String.to_integer(stop), String.to_integer(limit)}

             ats =
               case level do
                 "error" -> for at <- stop..start//-1, at >= 100 and at <= 200, do: at
                 "warning" -> for at <- [150, 105], at >= start and at <= stop, do: at
               end

             lines(for at <- Enum.take(ats, limit), do: record(at / 1, %{"level" => level}))
           end}
        ])

      store = %{store(plane) | most_incidents: 20}
      {incidents, store} = Store.incidents(store, 100.0, 200.0, 10)

      # The last twenty errors reach back to 181; each of the eight parts
      # before that was asked about, and has one.
      errors = incidents |> Enum.filter(& &1.error) |> Enum.map(& &1.at)
      assert length(errors) == 28
      assert Enum.count(errors, &(&1 >= 181)) == 20

      # One in the middle of each part that was asked about.
      assert Enum.sort(Enum.filter(errors, &(&1 < 181))) ==
               for(part <- 0..7, do: 105.0 + part * 10)

      # The kills were all read at once, and none was asked about again.
      assert Enum.filter(incidents, &(not &1.error)) ==
               [%{at: 105.0, error: false}, %{at: 150.0, error: false}]

      assert length(asked(plane, "/select/logsql/query")) == 2 + 8
      assert map_size(store.probed) == 8

      # A part of the past does not change, and is not asked about again.
      TestPlane.clear(plane)
      {again, store} = Store.incidents(store, 100.0, 200.0, 10)
      assert Enum.sort_by(again, & &1.at) == Enum.sort_by(incidents, & &1.at)
      assert length(asked(plane, "/select/logsql/query")) == 2

      # A part that has left the stretch is let go of.
      {_later, store} = Store.incidents(store, 150.0, 250.0, 10)
      assert Enum.all?(store.probed, fn {{_level, _start, stop}, _} -> stop >= 150 end)
    end

    test "is read from the last backwards, and what is wanted is chosen as it is read" do
      plane =
        plane([
          {"/select/logsql/query",
           fn %{"offset" => offset, "limit" => "1000", "order" => "desc"} ->
             page = div(String.to_integer(offset), 1000)

             # Three pages, the last of them short.
             count = if page < 2, do: 1000, else: 10

             lines(
               for n <- 1..count//1 do
                 at = 9000.0 - page * 1000 - n
                 status = if rem(n, 500) == 0, do: "killed", else: "normal"
                 record(at, %{"status" => status, "pid" => "<0.#{trunc(at)}.0>"})
               end
             )
           end}
        ])

      store = store(plane)
      reach = %{until: 9000.0, span: 3600.0, limit: 3}

      # The first that are wanted, and no further than is needed for them.
      assert {:ok, [first, _, _]} = Store.exits(store, reach, fn _ -> true end)
      assert %{at: 8999.0, pid: "<0.8999.0>", status: "normal", app: "my_app"} = first
      assert %{elapsed: 0.25, whole: true, name: "MyApp.Worker", level: "info"} = first
      assert [%{"start" => "5400", "end" => "9000"}] = asked(plane, "/select/logsql/query")

      # What is looked for is seldom among the last few.
      TestPlane.clear(plane)
      assert {:ok, killed} = Store.exits(store, reach, &(&1.status == "killed"))
      assert Enum.map(killed, & &1.at) == [8500.0, 8000.0, 7500.0]
      assert length(asked(plane, "/select/logsql/query")) == 2

      # To the end of what there is.
      TestPlane.clear(plane)
      assert {:ok, []} = Store.exits(store, reach, fn _ -> false end)
      assert length(asked(plane, "/select/logsql/query")) == 3
    end

    test "has a record, found by what it was and its pid" do
      plane =
        plane([
          {"/select/logsql/query",
           lines([
             record(510.0, %{"pid" => "<0.2.0>"}),
             record(520.0, %{"pid" => "<0.1.0>", "status" => "killed", "level" => "warning"}),
             record(530.0, %{"pid" => "<0.1.0>"})
           ])}
        ])

      store = store(plane)

      # The first of that pid to end after then: the one that was running.
      assert %{at: 520.0, status: "killed", level: "warning", fields: fields} =
               Store.record(store, "MyApp.Worker", "<0.1.0>", 500.0)

      assert fields["kind"] == "exit"
      refute Map.has_key?(fields, "_msg")

      assert [%{"service" => "MyApp.Worker", "start" => "500", "order" => "asc"}] =
               asked(plane, "/select/logsql/query")

      assert Store.record(store, "MyApp.Worker", "<0.9.0>", 500.0) == nil
    end

    test "says why it could not be read" do
      plane = plane([{"/select/logsql/query", {503, "busy"}}])

      assert {:error, why} =
               Store.exits(store(plane), %{until: 9.0, span: 5.0, limit: 3}, fn _ -> true end)

      assert why =~ "answered 503: busy"
      assert {[], _store} = Store.incidents(store(plane), 0.0, 9.0, 10)
      assert Store.record(store(plane), "A", "<0.1.0>", 0.0) == nil
    end
  end

  describe "jobs" do
    test "are the traces of more than one process, each read in full" do
      plane =
        plane([
          {"/select/timeless/api/spans",
           fn
             %{"offset" => "0"} ->
               %{
                 "entries" => [
                   span("aa", "02", "01", "MyApp.Worker", 102),
                   span("aa", "03", "01", "MyApp.Worker", 103),
                   # A trace of one process, and not a job.
                   span("bb", "04", nil, "MyApp.Session", 104),
                   span("cc", "06", "05", "fn in MyApp.Report.build/2", 111),
                   span("cc", "05", nil, "MyApp.Report.build/2", 110),
                   # Of another node.
                   span("dd", "07", nil, "X", 120, %{
                     "resource" => %{"service.instance.id" => "o@x"}
                   }),
                   span("dd", "08", "07", "X", 121, %{
                     "resource" => %{"service.instance.id" => "o@x"}
                   })
                 ]
               }

             _ ->
               %{"entries" => []}
           end},
          {"/select/timeless/api/traces/" <> String.duplicate("aa", 16),
           %{
             "spans" => [
               # Its root was not among the last spans, and is among its own.
               span("aa", "01", nil, "MyApp.Batch", 100, %{"duration_ns" => 5_000_000_000}),
               span("aa", "02", "01", "MyApp.Worker", 102),
               span("aa", "03", "01", "MyApp.Worker", 103, %{
                 "status" => "error",
                 "status_message" => "crashed: RuntimeError"
               })
             ]
           }},
          {"/select/timeless/api/traces/" <> String.duplicate("cc", 16),
           %{
             "spans" => [
               span("cc", "05", nil, "MyApp.Report.build/2", 110),
               span("cc", "06", "05", "fn in MyApp.Report.build/2", 111)
             ]
           }}
        ])

      store = store(plane)
      reach = %{until: 200.0, span: 900.0, limit: 10}

      # The last to start first.
      assert {:ok, [report, batch]} = Store.jobs(store, reach, 80, fn _ -> true end)

      assert %{name: "MyApp.Report.build/2", processes: 2, failed: 0, started: 110.0} = report
      assert report.duration == 3.0
      assert report.reductions == 1000

      assert %{name: "MyApp.Batch", app: "my_app", processes: 3, failed: 1, started: 100.0} =
               batch

      assert batch.duration == 5.0

      assert batch.tree == [
               "MyApp.Batch  5.0s, 500 reductions",
               "├─ MyApp.Worker  2.0s, 500 reductions",
               "└─ MyApp.Worker  2.0s, 500 reductions  [crashed: RuntimeError]"
             ]

      assert %{"until" => "200000000000", "order" => "desc", "limit" => "100"} =
               hd(asked(plane, "/select/timeless/api/spans"))

      # What is wanted is chosen among them.
      assert {:ok, [%{name: "MyApp.Batch"}]} = Store.jobs(store, reach, 80, &(&1.failed > 0))
    end

    test "say why they could not be read" do
      plane = plane([{"/select/timeless/api/spans", {500, ~s({"error":"internal"})}}])

      assert {:error, why} =
               Store.jobs(store(plane), %{until: 9.0, span: 5.0, limit: 3}, 80, fn _ -> true end)

      assert why =~ "answered 500: internal"
    end
  end
end
