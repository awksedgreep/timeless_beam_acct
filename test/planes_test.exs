defmodule TimelessBeamAcct.PlanesTest do
  @moduledoc """
  One tick, written through the HTTP sink to planes that are running, and
  read back from each of them.

  Every other test of the sink is against a server the tests run, which
  stores whatever it is sent. This one is against the servers themselves,
  and is what says that a sample, a record, and a span are stored as they
  were sent: under the same names, at the same times, as the same types.

  It is not run unless it is asked for, since it needs the planes and
  what it writes stays in them:

      TIMELESS_TEST_METRICS_URL=http://127.0.0.1:28428 \\
      TIMELESS_TEST_LOGS_URL=http://127.0.0.1:29428 \\
      TIMELESS_TEST_TRACES_URL=http://127.0.0.1:30428 \\
        mix test --only planes

  `TimelessBeamAcct.RealPlanes` says which planes it will write to, and
  which it refuses. Everything a run writes is under a host of its own,
  so a run reads back what it wrote and nothing of the runs before it.
  """

  use ExUnit.Case, async: false

  alias TimelessBeamAcct.{Batch, Event, Http, RealPlanes, Span, Tick}
  alias TimelessBeamAcct.Sink.Http, as: Sink

  @moduletag :planes
  @moduletag timeout: 60_000

  # Asked once, as the tests are compiled: of planes that are not
  # Timeless's, what they store is read by the watch's tests instead.
  @not_timeless RealPlanes.not_timeless()

  @node "planes@test"
  @metric "beam_planes_test_value"
  # How long a plane is given to show what it answered for.
  @within_ms 5_000

  setup_all do
    options =
      case RealPlanes.sink_options() do
        {:ok, options} -> options
        {:error, why} -> raise "not run: " <> why
      end

    {:ok, sink} = Sink.init(options ++ [timeout: 5])

    for {plane, url, result} <- Sink.check(sink) do
      case result do
        {:ok, _said} -> :ok
        {:error, why} -> raise "not run: the #{plane} plane at #{url}: #{why}"
      end
    end

    host = "planes-test-" <> Base.encode16(:rand.bytes(6), case: :lower)
    ts = System.os_time(:second)
    tick = tick(ts)

    case Sink.write(sink, host, @node, tick) do
      {:ok, _sink} -> :ok
      {:error, why, _sink} -> raise "the tick was not written: " <> why
    end

    {:ok, sink: sink, options: options, host: host, ts: ts, tick: tick}
  end

  ## The tick

  defp tick(ts) do
    %Tick{metrics: samples(ts), events: events(ts), spans: spans(ts)}
  end

  # As they are, and not as `Batch.push/4` would have rounded them: what
  # the encoder writes of any number is what is being tested.
  defp samples(ts) do
    samples = [
      {@metric, [{"case", "integer"}], 42},
      {@metric, [{"case", "negative"}], -7},
      {@metric, [{"case", "thousandths"}], 1.001},
      {@metric, [{"case", "bytes"}], 76_264_680},
      {@metric, [{"case", "small"}], 6.0e-5},
      {@metric, [{"case", "large"}], 1.0e21},
      {@metric, [{"case", "group"}, {"group", "fn in Busy.Request.handle/1"}], 1},
      {@metric, [{"case", "proc"}, {"proc", "Busy.Cache<0.258.0>"}, {"pid", "<0.258.0>"}], 2},
      {@metric, [{"case", "escaped"}, {"v", "a\"b\\c\nd"}], 3}
    ]

    %Batch{ts: ts, samples: Enum.reverse(samples), count: length(samples)}
  end

  defp events(ts) do
    # Not on a second, nor on a millisecond.
    us = ts * 1_000_000 + 123_456

    [
      %Event{
        ts_us: us,
        level: :info,
        message: "Planes.Worker<0.1.0> exited normal after 60µs, 12.3k reductions",
        fields: %{
          "service" => "Planes.Worker",
          "status" => "normal",
          "path" => "Planes.Worker.run/1",
          "pid" => "<0.1.0>",
          "reductions" => 12_345,
          "memory_bytes" => 76_264_680,
          "elapsed_seconds" => 6.0e-5
        }
      },
      %Event{
        ts_us: us + 1,
        level: :notice,
        message: "Planes.Request.handle/1<0.2.0> exited timeout after 1.5s",
        fields: %{
          "service" => "Planes.Request.handle/1",
          "status" => "timeout",
          "path" => "Planes.Request.handle/1",
          "reason" => "{:timeout, {Planes.Cache, :get, [7]}}",
          "elapsed_seconds" => 1.5
        }
      },
      %Event{
        ts_us: us + 2,
        level: :warning,
        message: "fn in Planes.Request.handle/1<0.3.0> killed after 2.0s",
        fields: %{
          "service" => "fn in Planes.Request.handle/1",
          "status" => "killed",
          "path" => "Planes.Request.-handle/1-fun-0-/0",
          # Whole, and a float all the same.
          "elapsed_seconds" => 2.0,
          "message_queue_len" => 0
        }
      },
      %Event{
        ts_us: us + 3,
        level: :error,
        message: "Planes.Request.handle/1<0.4.0> crashed: RuntimeError after 241µs",
        fields: %{
          "service" => "Planes.Request.handle/1",
          "status" => "RuntimeError",
          "path" => "Planes.Request.handle/1",
          "name" => "a\"b\\c\nd",
          "crashed" => true,
          "elapsed_seconds" => 2.41e-4
        }
      }
    ]
  end

  # A request, and the three tasks it started.
  defp spans(ts) do
    trace = :rand.bytes(16)
    request = :rand.bytes(8)
    start = ts * 1_000_000_000 + 123_456_789

    root = %Span{
      trace_id: trace,
      span_id: request,
      name: "Planes.Request.handle/1",
      service: "planes",
      ok: false,
      ending: "crashed: RuntimeError",
      start_ns: start,
      duration_ns: 241_000,
      attributes: %{
        "process.pid" => "<0.4.0>",
        "process.exit.status" => "RuntimeError",
        "process.reductions" => 4242,
        "process.peak_memory_bytes" => 76_264_680,
        "process.start_known" => true,
        "process.share" => 2.0
      }
    }

    tasks =
      for n <- 1..3 do
        %Span{
          trace_id: trace,
          span_id: :rand.bytes(8),
          parent_span_id: request,
          name: "fn in Planes.Request.handle/1",
          service: "planes",
          ok: true,
          ending: "exited normal",
          start_ns: start + n * 1_000,
          duration_ns: n * 10_000,
          attributes: %{"process.pid" => "<0.#{4 + n}.0>", "process.reductions" => n}
        }
      end

    [root | tasks]
  end

  ## Reading

  defp get(context, plane, path, query) do
    base = Keyword.fetch!(context.options, :"#{plane}_url")

    headers =
      case context.options[:"#{plane}_token"] do
        nil -> []
        token -> [{"Authorization", "Bearer " <> token}]
      end

    url = base <> path <> if(query == [], do: "", else: "?" <> URI.encode_query(query))

    case Http.get(url, headers, 5_000) do
      {:ok, 200, body} -> body
      {:ok, status, body} -> flunk("#{url} answered #{status}: #{body}")
      {:error, reason} -> flunk("#{url}: #{Http.format_error(reason)}")
    end
  end

  defp lines(body), do: body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

  # What was answered for is there to be read when it has been written,
  # which is at once, or soon.
  defp eventually(read, enough?, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @within_ms
    got = read.()

    cond do
      enough?.(got) ->
        got

      System.monotonic_time(:millisecond) >= deadline ->
        got

      true ->
        Process.sleep(50)
        eventually(read, enough?, deadline)
    end
  end

  defp stored_samples(context) do
    eventually(
      fn ->
        context
        |> get(:metrics, "/api/v1/export",
          metric: @metric,
          host: context.host,
          start: context.ts - 60,
          end: context.ts + 60
        )
        |> lines()
      end,
      &(length(&1) >= context.tick.metrics.count)
    )
  end

  defp stored_records(context, by \\ []) do
    eventually(
      fn ->
        context
        |> get(
          :logs,
          "/select/logsql/query",
          [host: context.host, order: "asc", limit: 100] ++ by
        )
        |> lines()
      end,
      &(by != [] or length(&1) >= length(context.tick.events))
    )
  end

  defp stored_spans(context) do
    [%Span{trace_id: trace} | _] = context.tick.spans

    eventually(
      fn ->
        context
        |> get(:traces, "/select/timeless/api/traces/" <> Span.hex(trace), [])
        |> JSON.decode!()
        |> Map.fetch!("spans")
      end,
      &(length(&1) >= length(context.tick.spans))
    )
  end

  defp promql(context, path, query) do
    body = get(context, :metrics, path, [{:lookback_delta, "30s"} | query])
    assert %{"status" => "success", "data" => %{"result" => result}} = JSON.decode!(body)
    result
  end

  defp microseconds(written) do
    {:ok, time, 0} = DateTime.from_iso8601(written)
    DateTime.to_unix(time, :microsecond)
  end

  ## Samples

  @tag skip: @not_timeless
  test "every sample is stored under its labels, with its value, at the time of its tick",
       context do
    sent =
      Map.new(Batch.samples(context.tick.metrics), fn {name, labels, value} ->
        series =
          labels
          |> Map.new()
          |> Map.merge(%{"__name__" => name, "host" => context.host, "node" => @node})

        {series, value}
      end)

    stored = stored_samples(context)

    assert stored |> Enum.map(& &1["metric"]) |> Enum.sort() == sent |> Map.keys() |> Enum.sort()

    for %{"metric" => series, "timestamps" => times, "values" => [value]} <- stored do
      # The second of the tick, and not the moment it arrived.
      assert times == [context.ts * 1000], "#{series["case"]} is stored at #{inspect(times)}"
      assert value == sent[series], "#{series["case"]} was sent as #{sent[series]}"
    end

    assert length(stored) == map_size(sent)
  end

  @tag skip: @not_timeless
  test "a query finds a sample for thirty seconds after it was taken, and not after", context do
    selector = ~s(#{@metric}{host="#{context.host}",case="bytes"})
    stored_samples(context)

    assert [%{"metric" => %{"case" => "bytes"}, "value" => [_, "76264680"]}] =
             promql(context, "/api/v1/query", query: selector, time: context.ts + 29)

    assert [] = promql(context, "/api/v1/query", query: selector, time: context.ts + 31)

    # A label that needs escaping is asked for as it is written.
    escaped = ~s(#{@metric}{host="#{context.host}",v=) <> ~S|"a\"b\\c\nd"}|

    assert [%{"metric" => %{"v" => "a\"b\\c\nd"}, "value" => [_, "3"]}] =
             promql(context, "/api/v1/query", query: escaped, time: context.ts)
  end

  @tag skip: @not_timeless
  test "a query over a range has the sample from its second on", context do
    stored_samples(context)

    assert [%{"values" => values}] =
             promql(context, "/api/v1/query_range",
               query: ~s(#{@metric}{host="#{context.host}",case="thousandths"}),
               start: context.ts - 4,
               end: context.ts + 4,
               step: 2
             )

    assert values == for(at <- [context.ts, context.ts + 2, context.ts + 4], do: [at, "1.001"])
  end

  ## Records

  @tag skip: @not_timeless
  test "every record is stored at its microsecond, at its level, with its fields as they were",
       context do
    stored = stored_records(context)
    assert length(stored) == length(context.tick.events)
    # In the order of their times, which is the order they were sent in.
    assert Enum.map(stored, & &1["_msg"]) == Enum.map(context.tick.events, & &1.message)

    for {%Event{} = event, record} <- Enum.zip(context.tick.events, stored) do
      assert record["level"] == Atom.to_string(event.level)
      assert microseconds(record["_time"]) == event.ts_us

      fields = Map.drop(record, ["_msg", "_time", "level"])
      sent = Map.merge(event.fields, %{"host" => context.host, "node" => @node})

      # An integer is not the float it is equal to, and is to be stored as
      # what it is.
      assert fields === sent
    end
  end

  @tag skip: @not_timeless
  test "records are found by their service, their status, and their path", context do
    stored_records(context)

    assert [%{"status" => "RuntimeError", "crashed" => true}] =
             stored_records(context, status: "RuntimeError")

    assert [%{"level" => "notice"}, %{"level" => "error"}] =
             stored_records(context, service: "Planes.Request.handle/1")

    assert [%{"level" => "warning"}] =
             stored_records(context, service: "fn in Planes.Request.handle/1")

    assert [%{"level" => "info"}] = stored_records(context, path: "Planes.Worker.run/1")
    assert [%{"level" => "notice"}] = stored_records(context, level: "notice")
    assert [] = stored_records(context, status: "no such ending")
  end

  ## Spans

  @tag skip: @not_timeless
  test "a trace is stored as the tree it was, each span as it began and ended", context do
    [root | tasks] = context.tick.spans
    stored = Map.new(stored_spans(context), &{&1["span_id"], &1})
    assert map_size(stored) == 4

    for %Span{} = span <- [root | tasks] do
      assert %{} = kept = stored[Span.hex(span.span_id)]
      assert kept["trace_id"] == Span.hex(span.trace_id)
      assert kept["name"] == span.name
      assert kept["kind"] == "internal"
      assert kept["start_time"] === span.start_ns
      assert kept["end_time"] === span.start_ns + span.duration_ns
      assert kept["status"] == if(span.ok, do: "ok", else: "error")
      assert kept["status_message"] == span.ending
      assert kept["attributes"] === span.attributes

      assert kept["resource"] === %{
               "service.name" => "planes",
               "host.name" => context.host,
               "service.instance.id" => @node
             }

      assert %{"name" => "timeless-beam-acct"} = kept["instrumentation_scope"]
    end

    assert stored[Span.hex(root.span_id)]["parent_span_id"] == nil

    for task <- tasks do
      assert stored[Span.hex(task.span_id)]["parent_span_id"] == Span.hex(root.span_id)
    end
  end

  @tag skip: @not_timeless
  test "the application is a service, and the group an operation of it", context do
    stored_spans(context)

    assert %{"data" => services} =
             context |> get(:traces, "/select/jaeger/api/services", []) |> JSON.decode!()

    assert "planes" in services

    assert %{"data" => operations} =
             context
             |> get(:traces, "/select/jaeger/api/services/planes/operations", [])
             |> JSON.decode!()

    assert "Planes.Request.handle/1" in operations
    assert "fn in Planes.Request.handle/1" in operations
  end

  ## The planes

  @tag skip: @not_timeless
  test "each plane says it is the plane it was taken for", context do
    for {plane, _url, result} <- Sink.check(context.sink) do
      assert {:ok, said} = result
      assert String.starts_with?(said, "answering: timeless-#{plane}-api ")
    end
  end
end

defmodule TimelessBeamAcct.RealPlanesTest do
  @moduledoc """
  Which planes the test above will write to. Nothing is sent to any of
  them here, so this is run with everything else.
  """

  use ExUnit.Case, async: true

  alias TimelessBeamAcct.RealPlanes

  @named %{
    "TIMELESS_TEST_METRICS_URL" => "http://127.0.0.1:28428",
    "TIMELESS_TEST_LOGS_URL" => "http://127.0.0.1:29428/",
    "TIMELESS_TEST_TRACES_URL" => "http://127.0.0.1:30428"
  }

  test "the planes are those the environment names" do
    assert RealPlanes.sink_options(@named) ==
             {:ok,
              [
                metrics_url: "http://127.0.0.1:28428",
                logs_url: "http://127.0.0.1:29428",
                traces_url: "http://127.0.0.1:30428"
              ]}
  end

  test "a plane that was not named is not guessed at" do
    assert {:error, why} = RealPlanes.sink_options(%{})
    assert why =~ "TIMELESS_TEST_METRICS_URL is not set"

    for variable <- Map.keys(@named) do
      assert {:error, why} = RealPlanes.sink_options(Map.delete(@named, variable))
      assert why =~ variable <> " is not set"
      assert {:error, why} = RealPlanes.sink_options(Map.put(@named, variable, ""))
      assert why =~ variable <> " is not set"
    end
  end

  test "the planes of this machine are refused, however this machine is written" do
    {:ok, hostname} = :inet.gethostname()

    for variable <- Map.keys(@named),
        port <- [8428, 9428, 10428],
        host <-
          ["127.0.0.1", "localhost", "LOCALHOST", "[::1]", "0.0.0.0", "127.8.4.2"] ++
            ["[::ffff:127.0.0.1]", List.to_string(hostname)],
        scheme <- ["http", "https"] do
      url = "#{scheme}://#{host}:#{port}"
      assert {:error, why} = RealPlanes.sink_options(Map.put(@named, variable, url)), url
      assert why =~ "#{variable} is #{url}"
      assert why =~ "a test does not write to those"
    end
  end

  test "a port is refused whichever plane it was given for" do
    crossed = Map.put(@named, "TIMELESS_TEST_TRACES_URL", "http://127.0.0.1:8428/")
    assert {:error, why} = RealPlanes.sink_options(crossed)
    assert why =~ "TIMELESS_TEST_TRACES_URL is http://127.0.0.1:8428/"
  end

  test "another port of this machine, and any port of another, may be written to" do
    # 192.0.2.0/24 is kept for writing about addresses, and is no machine.
    for url <- ["http://127.0.0.1:18428", "http://192.0.2.7:8428", "https://192.0.2.7:10428"] do
      named = Map.put(@named, "TIMELESS_TEST_METRICS_URL", url)
      assert {:ok, options} = RealPlanes.sink_options(named)
      assert options[:metrics_url] == url
    end
  end

  test "what is not a URL with a port is refused" do
    for url <- ["127.0.0.1:28428", "ftp://127.0.0.1:28428", "http://", "metrics"] do
      named = Map.put(@named, "TIMELESS_TEST_LOGS_URL", url)
      assert {:error, why} = RealPlanes.sink_options(named), url
      assert why =~ "expected an http or https URL"
    end
  end

  test "a token is for the plane it was named for" do
    named =
      Map.merge(@named, %{
        "TIMELESS_TEST_METRICS_TOKEN" => "m",
        "TIMELESS_TEST_TRACES_TOKEN" => "t",
        "TIMELESS_TEST_LOGS_TOKEN" => ""
      })

    assert {:ok, options} = RealPlanes.sink_options(named)
    assert options[:metrics_token] == "m"
    assert options[:traces_token] == "t"
    refute Keyword.has_key?(options, :logs_token)
  end
end
