defmodule TimelessBeamAcct.Sink.HttpTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.{Batch, Event, Span, TestPlane, Tick}
  alias TimelessBeamAcct.Sink.Http, as: Sink

  @metrics "/api/v1/import/prometheus"
  @logs "/insert/jsonline"
  @traces "/insert/opentelemetry/v1/traces"

  setup do
    planes =
      Map.new([:metrics, :logs, :traces], fn plane ->
        {plane, start_supervised!(Supervisor.child_spec(TestPlane, id: plane))}
      end)

    {:ok, planes}
  end

  # The context has more in it than the planes.
  defp all(planes), do: [planes.metrics, planes.logs, planes.traces]

  defp sink(planes, opts \\ []) do
    {:ok, sink} =
      [
        metrics_url: TestPlane.url(planes.metrics),
        logs_url: TestPlane.url(planes.logs),
        traces_url: TestPlane.url(planes.traces),
        timeout: 0.5
      ]
      |> Keyword.merge(opts)
      |> Sink.init()

    sink
  end

  # A tick taken at `ts`, with every part of it saying so.
  defp tick(ts, parts \\ [:metrics, :events, :spans]) do
    %Tick{
      metrics:
        if(:metrics in parts,
          do: Batch.push(Batch.new(ts), "vm_run_queue", ts),
          else: Batch.new(ts)
        ),
      events:
        if(:events in parts,
          do: [%Event{ts_us: ts * 1_000_000, level: :info, message: "at #{ts}"}],
          else: []
        ),
      spans:
        if(:spans in parts,
          do: [
            %Span{
              trace_id: <<ts::128>>,
              span_id: <<ts::64>>,
              name: "Shop.Worker",
              service: "shop",
              start_ns: ts * 1_000_000_000,
              duration_ns: 1
            }
          ],
          else: []
        )
    }
  end

  defp bodies(plane), do: plane |> TestPlane.requests() |> Enum.map(& &1.body)

  # The times the samples a metrics plane was sent were taken at, in the
  # order they arrived.
  defp sample_times(plane) do
    for body <- bodies(plane), line <- String.split(body, "\n", trim: true) do
      [_series, _value, ts_ms] = String.split(line, " ")
      div(String.to_integer(ts_ms), 1000)
    end
  end

  defp record_times(plane) do
    for body <- bodies(plane), line <- String.split(body, "\n", trim: true) do
      div(JSON.decode!(line)["_time"], 1_000_000)
    end
  end

  defp span_times(plane) do
    for body <- bodies(plane),
        resource <- JSON.decode!(body)["resourceSpans"],
        scope <- resource["scopeSpans"],
        span <- scope["spans"] do
      div(String.to_integer(span["startTimeUnixNano"]), 1_000_000_000)
    end
  end

  describe "a tick" do
    test "sends each signal to its endpoint, as its content type", planes do
      assert {:ok, sink} = Sink.write(sink(planes), "ohm", "app@ohm", tick(1_753_000_000))
      assert Sink.waiting(sink) == 0

      assert [%{method: "POST", path: @metrics} = samples] = TestPlane.requests(planes.metrics)
      assert samples.headers["content-type"] == "text/plain"

      assert samples.body ==
               ~s(vm_run_queue{host="ohm",node="app@ohm"} 1753000000 1753000000000\n)

      assert [%{method: "POST", path: @logs} = records] = TestPlane.requests(planes.logs)
      assert records.headers["content-type"] == "application/x-ndjson"

      assert JSON.decode!(records.body) == %{
               "_msg" => "at 1753000000",
               "_time" => 1_753_000_000_000_000,
               "level" => "info",
               "host" => "ohm",
               "node" => "app@ohm"
             }

      assert [%{method: "POST", path: @traces} = spans] = TestPlane.requests(planes.traces)
      assert spans.headers["content-type"] == "application/json"

      assert %{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [_]}]}]} =
               JSON.decode!(spans.body)
    end

    test "sends the token as a bearer, to every plane", planes do
      assert {:ok, _} = Sink.write(sink(planes, token: "s3cret"), "h", "n", tick(1))

      for plane <- all(planes) do
        assert [%{headers: %{"authorization" => "Bearer s3cret"}}] = TestPlane.requests(plane)
      end
    end

    test "sends a plane the token that is its own, and the others the one for all", planes do
      sink = sink(planes, token: "for-all", logs_token: "for-logs")
      assert {:ok, _} = Sink.write(sink, "h", "n", tick(1))

      assert [%{headers: %{"authorization" => "Bearer for-all"}}] =
               TestPlane.requests(planes.metrics)

      assert [%{headers: %{"authorization" => "Bearer for-logs"}}] =
               TestPlane.requests(planes.logs)

      assert [%{headers: %{"authorization" => "Bearer for-all"}}] =
               TestPlane.requests(planes.traces)
    end

    test "sends a token to the plane it is for, and none to a plane that has none", planes do
      sink = sink(planes, metrics_token: "for-metrics", traces_token: "for-traces")
      assert {:ok, _} = Sink.write(sink, "h", "n", tick(1))

      assert [%{headers: %{"authorization" => "Bearer for-metrics"}}] =
               TestPlane.requests(planes.metrics)

      assert [logs] = TestPlane.requests(planes.logs)
      refute Map.has_key?(logs.headers, "authorization")

      assert [%{headers: %{"authorization" => "Bearer for-traces"}}] =
               TestPlane.requests(planes.traces)
    end

    test "sends no authorization when there is no token", planes do
      assert {:ok, _} = Sink.write(sink(planes), "h", "n", tick(1))
      assert [request] = TestPlane.requests(planes.metrics)
      refute Map.has_key?(request.headers, "authorization")
    end

    test "posts nothing for a part of it that is empty", planes do
      sink = sink(planes)

      assert {:ok, sink} = Sink.write(sink, "h", "n", tick(1, [:metrics]))
      assert [_] = TestPlane.requests(planes.metrics)
      assert TestPlane.requests(planes.logs) == []
      assert TestPlane.requests(planes.traces) == []

      assert {:ok, sink} = Sink.write(sink, "h", "n", tick(2, [:events]))
      assert {:ok, sink} = Sink.write(sink, "h", "n", tick(3, [:spans]))
      assert {:ok, _} = Sink.write(sink, "h", "n", tick(4, []))

      assert sample_times(planes.metrics) == [1]
      assert record_times(planes.logs) == [2]
      assert span_times(planes.traces) == [3]
    end

    test "is posted to a base URL as it is, whether or not it ends in a slash", planes do
      sink =
        sink(planes,
          metrics_url: TestPlane.url(planes.metrics) <> "/",
          logs_url: TestPlane.url(planes.logs) <> "/behind/a/proxy//"
        )

      assert {:ok, _} = Sink.write(sink, "h", "n", tick(1))
      assert [%{path: @metrics}] = TestPlane.requests(planes.metrics)
      assert [%{path: "/behind/a/proxy" <> @logs}] = TestPlane.requests(planes.logs)
    end
  end

  describe "while a plane is down" do
    test "ticks are kept, and then sent in order, at the times they were taken", planes do
      sink = sink(planes)
      for plane <- all(planes), do: TestPlane.stop_listening(plane)

      sink =
        Enum.reduce(1..3, sink, fn ts, sink ->
          assert {:error, error, sink} = Sink.write(sink, "h", "n", tick(ts))
          assert error =~ "connection refused"
          assert error =~ "(#{ts * 3} waiting, 0 dropped so far)"
          assert Sink.waiting(sink) == ts * 3
          sink
        end)

      for plane <- all(planes), do: :ok = TestPlane.listen(plane)

      assert {:ok, sink} = Sink.write(sink, "h", "n", tick(4))
      assert Sink.waiting(sink) == 0
      assert Sink.dropped(sink) == 0

      # One body for each tick, and not one body of all of them.
      assert length(bodies(planes.metrics)) == 4
      assert sample_times(planes.metrics) == [1, 2, 3, 4]
      assert record_times(planes.logs) == [1, 2, 3, 4]
      assert span_times(planes.traces) == [1, 2, 3, 4]
    end

    test "a flush sends what is waiting", planes do
      sink = sink(planes)
      TestPlane.stop_listening(planes.metrics)

      assert {:error, _, sink} = Sink.write(sink, "h", "n", tick(1, [:metrics]))
      assert {:error, error, sink} = Sink.flush(sink)
      assert error =~ "connection refused"
      assert Sink.waiting(sink) == 1

      :ok = TestPlane.listen(planes.metrics)
      assert {:ok, sink} = Sink.flush(sink)
      assert Sink.waiting(sink) == 0
      assert sample_times(planes.metrics) == [1]

      # And then there is nothing to send.
      assert {:ok, _} = Sink.flush(sink)
      assert sample_times(planes.metrics) == [1]
    end

    test "the oldest is dropped past capacity, and the error counts it", planes do
      # Two ticks, which is six bodies.
      sink = sink(planes, backlog: 2)
      for plane <- all(planes), do: TestPlane.stop_listening(plane)

      assert {:error, error, sink} = Sink.write(sink, "h", "n", tick(1))
      assert error =~ "(3 waiting, 0 dropped so far)"
      assert {:error, error, sink} = Sink.write(sink, "h", "n", tick(2))
      assert error =~ "(6 waiting, 0 dropped so far)"
      assert {:error, error, sink} = Sink.write(sink, "h", "n", tick(3))
      assert error =~ "(6 waiting, 3 dropped so far)"
      assert {:error, error, sink} = Sink.write(sink, "h", "n", tick(4, [:metrics]))
      assert error =~ "(6 waiting, 4 dropped so far)"
      assert Sink.dropped(sink) == 4

      for plane <- all(planes), do: :ok = TestPlane.listen(plane)
      assert {:ok, sink} = Sink.flush(sink)

      # The first tick went, and the samples of the second.
      assert sample_times(planes.metrics) == [3, 4]
      assert record_times(planes.logs) == [2, 3]
      assert span_times(planes.traces) == [2, 3]
      assert Sink.dropped(sink) == 4
    end

    test "a backlog of no ticks still holds one", planes do
      sink = sink(planes, backlog: 0)
      TestPlane.stop_listening(planes.metrics)

      assert {:error, _, sink} = Sink.write(sink, "h", "n", tick(1, [:metrics]))
      assert Sink.waiting(sink) == 1
    end

    test "it does not hold back the others", planes do
      sink = sink(planes)
      TestPlane.stop_listening(planes.logs)

      sink =
        Enum.reduce(1..3, sink, fn ts, sink ->
          assert {:error, error, sink} = Sink.write(sink, "ohm", "n", tick(ts))
          assert error =~ TestPlane.url(planes.logs) <> @logs
          assert error =~ "connection refused"
          assert error =~ "(#{ts} waiting, 0 dropped so far)"
          sink
        end)

      assert sample_times(planes.metrics) == [1, 2, 3]
      assert span_times(planes.traces) == [1, 2, 3]
      assert record_times(planes.logs) == []

      :ok = TestPlane.listen(planes.logs)
      assert {:ok, sink} = Sink.write(sink, "ohm", "n", tick(4))

      assert Sink.waiting(sink) == 0
      assert record_times(planes.logs) == [1, 2, 3, 4]
      assert sample_times(planes.metrics) == [1, 2, 3, 4]
      assert span_times(planes.traces) == [1, 2, 3, 4]
    end

    test "it is asked once in a drain, however much is waiting for it", planes do
      sink = sink(planes, timeout: 0.2)
      # It accepts, and never answers: every post to it costs the timeout.
      TestPlane.mode(planes.logs, :hang)

      sink =
        Enum.reduce(1..3, sink, fn ts, sink ->
          assert {:error, error, sink} = Sink.write(sink, "h", "n", tick(ts))
          assert error =~ "timed out"
          sink
        end)

      TestPlane.clear(planes.logs)
      started = System.monotonic_time(:millisecond)
      assert {:error, error, sink} = Sink.write(sink, "h", "n", tick(4))
      took = System.monotonic_time(:millisecond) - started

      assert error =~ "(4 waiting, 0 dropped so far)"
      assert Sink.waiting(sink) == 4
      # Four bodies were waiting for it, and it was asked for the first.
      assert [%{body: body}] = TestPlane.requests(planes.logs)
      assert JSON.decode!(body)["_msg"] == "at 1"
      # Which cost one timeout, and not four.
      assert took < 600
      assert sample_times(planes.metrics) == [1, 2, 3, 4]
    end

    test "the error is the first that was met", planes do
      sink = sink(planes)
      TestPlane.stop_listening(planes.metrics)
      TestPlane.respond_with(planes.traces, 503, "busy")

      assert {:error, error, sink} = Sink.write(sink, "h", "n", tick(1))
      assert error =~ TestPlane.url(planes.metrics) <> @metrics <> ": connection refused"
      refute error =~ "busy"
      assert error =~ "(2 waiting, 0 dropped so far)"
      assert Sink.waiting(sink) == 2
      assert record_times(planes.logs) == [1]
    end
  end

  describe "a plane that answers with a failure" do
    test "has failed, and the body is kept for the next drain", planes do
      sink = sink(planes)
      TestPlane.respond_with(planes.metrics, 500, "  the store is full\n")

      assert {:error, error, sink} = Sink.write(sink, "h", "n", tick(1))

      assert error ==
               "#{TestPlane.url(planes.metrics)}#{@metrics} answered 500: the store is full " <>
                 "(1 waiting, 0 dropped so far)"

      assert Sink.waiting(sink) == 1
      assert sample_times(planes.metrics) == [1]
      assert record_times(planes.logs) == [1]

      TestPlane.clear(planes.metrics)
      TestPlane.respond_with(planes.metrics, 204, "")

      assert {:ok, sink} = Sink.write(sink, "h", "n", tick(2))
      assert Sink.waiting(sink) == 0
      # What was refused was sent again, before what came after it.
      assert sample_times(planes.metrics) == [1, 2]
      assert record_times(planes.logs) == [1, 2]
    end

    test "that says the body is what is wrong is not sent it again", planes do
      sink = sink(planes)
      TestPlane.respond_with(planes.logs, 400, "line 1: not JSON")

      assert {:error, error, sink} = Sink.write(sink, "h", "n", tick(1))

      assert error ==
               "#{TestPlane.url(planes.logs)}#{@logs} refused what it was sent, " <>
                 "with 400: line 1: not JSON (0 waiting, 0 dropped so far)"

      assert Sink.waiting(sink) == 0
      assert Sink.refused(sink) == 1
      assert sample_times(planes.metrics) == [1]

      # What comes after it is not held up behind it.
      TestPlane.clear(planes.logs)
      TestPlane.respond_with(planes.logs, 204, "")
      assert {:ok, sink} = Sink.write(sink, "h", "n", tick(2))
      assert record_times(planes.logs) == [2]
      assert Sink.refused(sink) == 1
    end

    test "that read only some of the records has failed, and is not sent them again", planes do
      # What the logs plane answers a body with a line in it that it
      # cannot read: the rest is stored, and the status is 200.
      sink = sink(planes)
      TestPlane.respond_with(planes.logs, 200, ~s({"entries":41,"errors":1}))

      assert {:error, error, sink} = Sink.write(sink, "h", "n", tick(1))

      assert error ==
               "#{TestPlane.url(planes.logs)}#{@logs} could not read 1 of the records " <>
                 "it was sent, and stored 41 (0 waiting, 0 dropped so far)"

      assert Sink.waiting(sink) == 0
      assert Sink.refused(sink) == 1
      assert sample_times(planes.metrics) == [1]
      assert span_times(planes.traces) == [1]

      TestPlane.respond_with(planes.logs, 204, "")
      assert {:ok, sink} = Sink.write(sink, "h", "n", tick(2))
      assert record_times(planes.logs) == [1, 2]
      assert Sink.refused(sink) == 1
    end

    test "that read every record has stored them, whatever else it says", planes do
      TestPlane.respond_with(planes.logs, 200, ~s({"entries":1,"errors":0}))
      # Only the logs plane counts what it could not read in its answer.
      TestPlane.respond_with(planes.metrics, 200, ~s({"entries":0,"errors":1}))
      TestPlane.respond_with(planes.traces, 200, "{}")

      assert {:ok, sink} = Sink.write(sink(planes), "h", "n", tick(1))
      assert Sink.refused(sink) == 0

      for said <- ["ok", "[1]", ~s({"errors":"1"}), ~s({"errors":-1}), ~s({"errors":)] do
        TestPlane.respond_with(planes.logs, 200, said)
        assert {:ok, sink} = Sink.write(sink, "h", "n", tick(2, [:events]))
        assert Sink.refused(sink) == 0
      end
    end

    test "is reported without a body if it sent none", planes do
      TestPlane.respond_with(planes.logs, 401, "")

      assert {:error, error, _} = Sink.write(sink(planes), "h", "n", tick(1, [:events]))

      assert error ==
               "#{TestPlane.url(planes.logs)}#{@logs} answered 401 (1 waiting, 0 dropped so far)"
    end
  end

  describe "the options" do
    test "default to the planes of this host" do
      assert {:ok, sink} = Sink.init([])

      assert Sink.describe(sink) ==
               "http: http://127.0.0.1:8428/api/v1/import/prometheus, " <>
                 "http://127.0.0.1:9428/insert/jsonline, and " <>
                 "http://127.0.0.1:10428/insert/opentelemetry/v1/traces"

      assert sink.timeout_ms == 5_000
      assert sink.capacity == 360 * 3
      assert Sink.waiting(sink) == 0
      assert Sink.dropped(sink) == 0
      assert Sink.close(sink) == :ok
    end

    test "take a timeout as a number of seconds, or written" do
      assert {:ok, %{timeout_ms: 2_000}} = Sink.init(timeout: 2)
      assert {:ok, %{timeout_ms: 250}} = Sink.init(timeout: 0.25)
      assert {:ok, %{timeout_ms: 30_000}} = Sink.init(timeout: "30s")
      assert {:ok, %{timeout_ms: 60_000}} = Sink.init(timeout: "1m")
    end

    test "refuse a URL that is not http or https" do
      for key <- [:metrics_url, :logs_url, :traces_url],
          url <- ["ftp://127.0.0.1", "127.0.0.1:8428", "http://", "", nil, :localhost] do
        assert {:error, why} = Sink.init([{key, url}]), "#{inspect(url)} was accepted"
        assert why =~ inspect(key)
        assert why =~ "expected an http or https URL"
      end

      assert {:ok, _} = Sink.init(metrics_url: "https://metrics.example.com/")
    end

    test "refuse what is not an option, and what is not a value for one" do
      assert {:error, why} = Sink.init(metric_url: "http://127.0.0.1:1")
      assert why =~ "unknown option :metric_url"

      assert {:error, _} = Sink.init(timeout: 0)
      assert {:error, _} = Sink.init(timeout: "soon")
      assert {:error, _} = Sink.init(timeout: nil)
      assert {:error, _} = Sink.init(backlog: -1)
      assert {:error, _} = Sink.init(backlog: 1.5)
      assert {:error, _} = Sink.init(token: :secret)
      assert {:error, _} = Sink.init(token: "two\r\nlines")
      assert {:error, _} = Sink.init(token: "")

      for key <- [:metrics_token, :logs_token, :traces_token] do
        assert {:error, why} = Sink.init([{key, :secret}, {:token, "good"}])
        assert why == "#{inspect(key)} is not a string"
        assert {:error, why} = Sink.init([{key, "two\r\nlines"}])
        assert why == "#{inspect(key)} cannot be sent as a header"
      end

      assert {:error, _} = Sink.init(%{})
    end
  end

  describe "a check" do
    test "asks each plane whether it is there, and says what answered", planes do
      TestPlane.respond_with(planes.metrics, 200, ~s({"status":\n "ok"}\n))
      TestPlane.respond_with(planes.logs, 200, "")
      TestPlane.respond_with(planes.traces, 200, String.duplicate("a long answer ", 100))

      assert Sink.check(sink(planes, token: "s3cret")) == [
               {:metrics, TestPlane.url(planes.metrics), {:ok, ~s(answering: {"status": "ok"})}},
               {:logs, TestPlane.url(planes.logs), {:ok, "answering"}},
               {:traces, TestPlane.url(planes.traces), {:ok, "answering"}}
             ]

      for plane <- all(planes) do
        assert [%{method: "GET", path: "/health"} = request] = TestPlane.requests(plane)
        assert request.headers["authorization"] == "Bearer s3cret"
      end
    end

    # What the planes answer for /health, as of 0.8.5, cut short.
    defp health(name, rest) do
      ~s({"admitted_batches":20,"admitted_points":25971,"buffered_points":1404,) <>
        ~s("build":{"commit":"726f847fc2129dfcc38a8871aa6974b4e0cf61fb","name":"#{name}",) <>
        ~s("profile":"release","target":"x86_64-unknown-linux-gnu","version":"0.8.5"},) <>
        ~s("completed_batches":20,"database_file_bytes":4669440,"import_errors":4,) <>
        ~s("otel_traces_state":"disabled","queued_points":0,"series":2344,#{rest}})
    end

    test "says what a plane says it is, and none of the rest of what it says", planes do
      TestPlane.respond_with(
        planes.metrics,
        200,
        health("timeless-metrics-api", ~s("status":"ok"))
      )

      TestPlane.respond_with(planes.logs, 200, health("timeless-logs-api", ~s("status":"ok")))

      TestPlane.respond_with(
        planes.traces,
        200,
        health("timeless-traces-api", ~s("status":"ready"))
      )

      assert Sink.check(sink(planes)) == [
               {:metrics, TestPlane.url(planes.metrics),
                {:ok, "answering: timeless-metrics-api 0.8.5"}},
               {:logs, TestPlane.url(planes.logs), {:ok, "answering: timeless-logs-api 0.8.5"}},
               {:traces, TestPlane.url(planes.traces),
                {:ok, "answering: timeless-traces-api 0.8.5"}}
             ]
    end

    test "says that a plane is another plane than the one it was taken for", planes do
      # The URLs of two planes, each given for the other.
      TestPlane.respond_with(planes.metrics, 200, health("timeless-logs-api", ~s("status":"ok")))
      TestPlane.respond_with(planes.logs, 200, health("timeless-metrics-api", ~s("status":"ok")))
      # What is not one of the three is not said to be the wrong one.
      TestPlane.respond_with(planes.traces, 200, ~s({"build":{"name":"a-proxy"}}))

      assert [
               {:metrics, _,
                {:error, "answering as timeless-logs-api 0.8.5, which is not the metrics plane"}},
               {:logs, _,
                {:error, "answering as timeless-metrics-api 0.8.5, which is not the logs plane"}},
               {:traces, _, {:ok, "answering: a-proxy"}}
             ] = Sink.check(sink(planes))
    end

    test "asks each plane with the token that is its own", planes do
      Sink.check(sink(planes, token: "for-all", traces_token: "for-traces"))

      assert [%{headers: %{"authorization" => "Bearer for-all"}}] =
               TestPlane.requests(planes.metrics)

      assert [%{headers: %{"authorization" => "Bearer for-traces"}}] =
               TestPlane.requests(planes.traces)
    end

    test "says which plane is not there, and which answered something else", planes do
      TestPlane.stop_listening(planes.logs)
      TestPlane.respond_with(planes.traces, 404, "no such route")

      assert [
               {:metrics, _, {:ok, "answering"}},
               {:logs, logs_url, {:error, "connection refused"}},
               {:traces, _, {:error, "/health answered 404: no such route"}}
             ] = Sink.check(sink(planes))

      assert logs_url == TestPlane.url(planes.logs)
    end

    test "sends nothing that was waiting", planes do
      sink = sink(planes)
      TestPlane.stop_listening(planes.metrics)
      assert {:error, _, sink} = Sink.write(sink, "h", "n", tick(1, [:metrics]))
      :ok = TestPlane.listen(planes.metrics)

      assert [{:metrics, _, {:ok, _}}, _, _] = Sink.check(sink)
      assert [%{method: "GET"}] = TestPlane.requests(planes.metrics)
      assert Sink.waiting(sink) == 1
    end
  end
end
