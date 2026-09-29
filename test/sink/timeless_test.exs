defmodule TimelessBeamAcct.Sink.TimelessTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.{Batch, Event, FakeLogs, FakeMetrics, FakeStores, FakeTraces, Span, Tick}
  alias TimelessBeamAcct.{FakeTracesLibrary, FakeWithNothing, FakeWithoutFlush}
  alias TimelessBeamAcct.Sink
  alias TimelessBeamAcct.Sink.Timeless

  @host "ohm"
  @node "acct@ohm"
  @ts 1_753_000_000

  @fakes [
    metrics: :acct,
    metrics_module: FakeMetrics,
    logs_module: FakeLogs,
    traces_module: FakeTraces
  ]

  setup do
    FakeStores.start()
  end

  defp sink(opts \\ []) do
    {:ok, state} = Timeless.init(Keyword.merge(@fakes, opts))
    state
  end

  defp batch do
    Batch.new(@ts)
    |> Batch.push("beam_memory_total_bytes", 123_456_789)
    |> Batch.push("beam_proc_reductions_per_sec", [{"pid", "<0.99.0>"}, {"group", "Ecto"}], 12.5)
  end

  defp event do
    %Event{
      ts_us: @ts * 1_000_000 + 1,
      level: :notice,
      message: "Ecto.Repo <0.99.0> exited: shutdown",
      fields: %{
        "service" => "ecto",
        "status" => "shutdown",
        "pid" => "<0.99.0>",
        "reductions" => 4242,
        "memory_mb" => 2.5,
        "trapping" => true
      }
    }
  end

  defp span(changes \\ []) do
    struct!(
      %Span{
        trace_id: :binary.copy(<<0xAB>>, 16),
        span_id: :binary.copy(<<0x01>>, 8),
        parent_span_id: :binary.copy(<<0x02>>, 8),
        name: "Ecto",
        service: "ecto",
        ok: false,
        ending: "killed",
        start_ns: @ts * 1_000_000_000,
        duration_ns: 2_500_000_000,
        attributes: %{
          "process.pid" => "<0.99.0>",
          "process.reductions" => 4242,
          "process.memory_mb" => 2.5,
          "process.trapping" => true
        }
      },
      changes
    )
  end

  defp tick(parts \\ []) do
    struct!(%Tick{metrics: batch(), events: [event()], spans: [span()]}, parts)
  end

  defp empty, do: Batch.new(@ts)

  describe "the sink" do
    test "is the one the collector calls :timeless" do
      assert Sink.module(:timeless) == Timeless
    end

    test "is every callback of a sink" do
      Code.ensure_loaded!(Timeless)

      for {function, arity} <- [init: 1, write: 4, flush: 1, close: 1, describe: 1] do
        assert function_exported?(Timeless, function, arity)
      end
    end
  end

  describe "samples" do
    test "reach the metrics store as write_batch entries, at the time of the batch" do
      assert {:ok, _} = Timeless.write(sink(), @host, @node, tick())

      assert FakeStores.calls(:metrics) == [
               write_batch: [
                 :acct,
                 [
                   {"beam_memory_total_bytes", %{"host" => "ohm", "node" => "acct@ohm"},
                    123_456_789.0, @ts},
                   {"beam_proc_reductions_per_sec",
                    %{
                      "host" => "ohm",
                      "node" => "acct@ohm",
                      "pid" => "<0.99.0>",
                      "group" => "Ecto"
                    }, 12.5, @ts}
                 ]
               ]
             ]
    end

    test "are floats, as the text route parses them" do
      assert [{_, _, value, _}] =
               Timeless.samples(@host, @node, Batch.push(empty(), "beam_processes", 7))

      assert value === 7.0
    end

    test "have labels that are strings, whatever they were given as" do
      batch = Batch.push(empty(), "beam_ets_objects", [{:table, :sessions}, {"id", 7}], 1)

      assert [{_, labels, _, _}] = Timeless.samples(@host, @node, batch)

      assert labels == %{
               "table" => "sessions",
               "id" => "7",
               "host" => "ohm",
               "node" => "acct@ohm"
             }
    end

    test "are of this host and this node, whatever a label of their own says" do
      batch = Batch.push(empty(), "beam_dist_queue", [{"node", "other@far"}, {"host", "far"}], 1)

      assert [{_, %{"host" => "ohm", "node" => "acct@ohm"}, _, _}] =
               Timeless.samples(@host, @node, batch)
    end

    test "go to the store that was named" do
      state = sink(metrics: :another)
      assert {:ok, _} = Timeless.write(state, @host, @node, tick())
      assert [write_batch: [:another, _]] = FakeStores.calls(:metrics)
    end

    test "go to timeless_phoenix's store when none is named" do
      assert Timeless.default_store() == :tp_default_timeless

      state = sink(metrics: true)
      assert state.metrics == :tp_default_timeless

      {:ok, state} = Timeless.init(Keyword.delete(@fakes, :metrics))
      assert state.metrics == :tp_default_timeless
    end
  end

  describe "records" do
    test "reach the logs store as entries, with their fields and host and node as metadata" do
      assert {:ok, _} = Timeless.write(sink(), @host, @node, tick())

      assert FakeStores.calls(:logs) == [
               ingest: [
                 [
                   %{
                     timestamp: 1_753_000_000_000_001,
                     level: :notice,
                     message: "Ecto.Repo <0.99.0> exited: shutdown",
                     metadata: %{
                       "service" => "ecto",
                       "status" => "shutdown",
                       "pid" => "<0.99.0>",
                       "reductions" => 4242,
                       "memory_mb" => 2.5,
                       "trapping" => true,
                       "host" => "ohm",
                       "node" => "acct@ohm"
                     }
                   }
                 ]
               ]
             ]
    end

    test "keep the types of their fields: a number is a number and a flag is a flag" do
      assert [%{metadata: metadata}] = Timeless.entries(@host, @node, [event()])
      assert metadata["reductions"] === 4242
      assert metadata["memory_mb"] === 2.5
      assert metadata["trapping"] === true
    end

    test "keep their level, each of the four" do
      events = for level <- [:info, :notice, :warning, :error], do: %{event() | level: level}

      assert [:info, :notice, :warning, :error] ==
               Enum.map(Timeless.entries(@host, @node, events), & &1.level)
    end

    test "are of this host and this node, whatever a field of their own says" do
      event = %{event() | fields: %{"host" => "far", "node" => "other@far"}}

      assert [%{metadata: %{"host" => "ohm", "node" => "acct@ohm"}}] =
               Timeless.entries(@host, @node, [event])
    end

    test "are handed over together, in the order they were made" do
      events = for n <- 1..3, do: %{event() | message: "exit #{n}", ts_us: n}
      assert {:ok, _} = Timeless.write(sink(), @host, @node, tick(events: events))

      assert [ingest: [entries]] = FakeStores.calls(:logs)
      assert Enum.map(entries, & &1.message) == ["exit 1", "exit 2", "exit 3"]
    end
  end

  describe "spans" do
    test "reach the traces store as the OTLP route would have made them" do
      assert {:ok, _} = Timeless.write(sink(), @host, @node, tick())

      assert FakeStores.calls(:traces) == [
               ingest: [
                 [
                   %{
                     trace_id: String.duplicate("ab", 16),
                     span_id: String.duplicate("01", 8),
                     parent_span_id: String.duplicate("02", 8),
                     name: "Ecto",
                     kind: :internal,
                     start_time: 1_753_000_000_000_000_000,
                     end_time: 1_753_000_002_500_000_000,
                     duration_ns: 2_500_000_000,
                     status: :error,
                     status_message: "killed",
                     attributes: %{
                       "process.pid" => "<0.99.0>",
                       "process.reductions" => 4242,
                       "process.memory_mb" => 2.5,
                       "process.trapping" => true
                     },
                     events: [],
                     resource: %{
                       "service.name" => "ecto",
                       "host.name" => "ohm",
                       "service.instance.id" => "acct@ohm"
                     },
                     instrumentation_scope: %{
                       name: "timeless-beam-acct",
                       version: to_string(Application.spec(:timeless_beam_acct, :vsn))
                     }
                   }
                 ]
               ]
             ]
    end

    test "end when they started plus how long they took" do
      for %{start_time: start, end_time: finish, duration_ns: duration} <-
            Timeless.spans(@host, @node, [span(), span(duration_ns: 0)]) do
        assert finish == start + duration
      end
    end

    test "with no parent have none" do
      assert [%{parent_span_id: nil}] =
               Timeless.spans(@host, @node, [span(parent_span_id: nil)])
    end

    test "say how the process ended, or that it is not known" do
      spans = [span(ok: true), span(ok: false), span(ok: nil)]

      assert [:ok, :error, :unset] ==
               Enum.map(Timeless.spans(@host, @node, spans), & &1.status)
    end

    test "are taken by the library a level down, where it has no ingest of its own" do
      state = sink(traces_module: FakeTracesLibrary)
      assert state.traces_ingest == FakeTracesLibrary.StorageEngine

      assert {:ok, _} = Timeless.write(state, @host, @node, tick())
      assert [ingest: [[%{name: "Ecto"}]]] = FakeStores.calls(:traces)
    end
  end

  describe "a signal that is turned off" do
    test "is not written" do
      state = sink(metrics: false, traces: false)
      assert {:ok, _} = Timeless.write(state, @host, @node, tick())
      assert [{:logs, :ingest, _}] = FakeStores.calls()
    end

    test "is not flushed" do
      state = sink(logs: false)
      assert {:ok, _} = Timeless.flush(state)
      assert [{:metrics, :flush, [:acct]}, {:traces, :flush, []}] = FakeStores.calls()
    end

    test "is not checked: its library need not be there" do
      # `TimelessMetrics` and `TimelessLogs` are not in this node.
      assert {:ok, state} =
               Timeless.init(metrics: false, logs: false, traces_module: FakeTraces)

      assert {:ok, _} = Timeless.write(state, @host, @node, tick())
      assert [{:traces, :ingest, _}] = FakeStores.calls()
    end

    test "is not checked: its store need not be running" do
      FakeStores.tell(:logs, :running?, false)
      assert {:ok, _} = Timeless.init(Keyword.merge(@fakes, logs: false))
    end

    test "leaves no sink if it is every signal" do
      assert {:error, why} = Timeless.init(metrics: false, logs: false, traces: false)
      assert why =~ "all off"
    end
  end

  describe "an empty part of a tick" do
    test "writes nothing to its store" do
      assert {:ok, _} = Timeless.write(sink(), @host, @node, tick(metrics: empty(), spans: []))
      assert [{:logs, :ingest, _}] = FakeStores.calls()
    end

    test "is not a failure of a store that would have failed" do
      FakeStores.tell(:traces, :ingest, :raise)
      assert {:ok, state} = Timeless.write(sink(), @host, @node, tick(spans: []))
      assert state.lost_ticks == 0
    end

    test "that is all of the tick calls no store at all" do
      nothing = %Tick{metrics: empty()}
      assert Tick.empty?(nothing)
      assert {:ok, _} = Timeless.write(sink(), @host, @node, nothing)
      assert FakeStores.calls() == []
    end
  end

  describe "a library that is not there" do
    test "is refused when the sink starts, by the name of its package" do
      assert {:error, why} = Timeless.init(metrics: :acct, logs: false, traces: false)
      assert why =~ "metrics: TimelessMetrics is not loaded"
      assert why =~ ":timeless_metrics is not in this node"
      assert why =~ ~s({:timeless_metrics, "~> 6.6"})
      assert why =~ "metrics: false"

      assert {:error, why} = Timeless.init(metrics: false, logs: true, traces: false)
      assert why =~ "logs: TimelessLogs is not loaded"
      assert why =~ ~s({:timeless_logs, "~> 1.11"})

      assert {:error, why} = Timeless.init(metrics: false, logs: false, traces: true)
      assert why =~ "traces: TimelessTraces is not loaded"
      assert why =~ ~s({:timeless_traces, "~> 1.11"})
    end

    test "is refused though the others are there" do
      assert {:error, why} = Timeless.init(Keyword.delete(@fakes, :logs_module))
      assert why =~ "logs: TimelessLogs is not loaded"
    end

    test "is refused by its own name when it is a module put in between" do
      assert {:error, why} = Timeless.init(Keyword.merge(@fakes, logs_module: No.Such.Module))
      assert why =~ "logs: No.Such.Module, given as :logs_module, is not loaded"
    end
  end

  describe "a library that is there" do
    test "and does not export what is called is refused, by the function" do
      assert {:error, why} = Timeless.init(Keyword.merge(@fakes, metrics_module: FakeWithNothing))
      assert why =~ "metrics: TimelessBeamAcct.FakeWithNothing does not export write_batch/2"

      assert {:error, why} = Timeless.init(Keyword.merge(@fakes, logs_module: FakeWithNothing))
      assert why =~ "logs: TimelessBeamAcct.FakeWithNothing does not export ingest/1"

      assert {:error, why} = Timeless.init(Keyword.merge(@fakes, traces_module: FakeWithNothing))
      assert why =~ "traces: neither TimelessBeamAcct.FakeWithNothing nor"
      assert why =~ "FakeWithNothing.StorageEngine exports ingest/1"
    end

    test "and whose store is not running is refused, by the name of the store" do
      FakeStores.tell(:metrics, :running?, false)
      assert {:error, why} = Timeless.init(@fakes)
      assert why =~ "metrics: no store named :acct is running in this node"
      assert why =~ "name: :acct"
    end

    test "and whose store is not running is refused, by the signal, where stores have no name" do
      FakeStores.tell(:traces, :running?, false)
      assert {:error, why} = Timeless.init(@fakes)
      assert why =~ "traces: the store of TimelessBeamAcct.FakeTraces is not running"
      assert why =~ ":timeless_traces"
      assert why =~ "traces: false"
    end

    test "and cannot say whether its store is running is taken to be" do
      assert {:ok, _} = Timeless.init(Keyword.merge(@fakes, logs_module: FakeWithoutFlush))
    end
  end

  describe "options" do
    test "that are not known are refused by name" do
      assert {:error, why} = Timeless.init(Keyword.merge(@fakes, metric: :acct))
      assert why =~ "unknown option :metric"
    end

    test "that are not what they should be are refused by name" do
      for {key, value} <- [
            metrics: "acct",
            metrics: nil,
            logs: :yes,
            traces: 1,
            logs_module: "TimelessLogs",
            timeout: 0,
            timeout: "soon",
            timeout: :never
          ] do
        assert {:error, why} = Timeless.init(Keyword.merge(@fakes, [{key, value}]))
        assert why =~ inspect(key)
      end
    end

    test "give a store a length of time to answer, as a number or written" do
      assert sink().timeout == 30_000
      assert sink(timeout: 2).timeout == 2_000
      assert sink(timeout: "1m").timeout == 60_000
    end
  end

  describe "a store that fails" do
    for {told, says} <- [
          {{:error, :unavailable}, ":unavailable"},
          {{:error, "the disk is full"}, "the disk is full"},
          {:raise, "raised RuntimeError: the fake metrics store raised in write_batch"},
          {:exit, "exited: no process: the process is not alive"},
          {:break_link, "exited: :the_linked_process_died"},
          {{:answer, :what}, "answered :what"}
        ] do
      test "by #{inspect(told)} is an error that names the signal" do
        FakeStores.tell(:metrics, :write_batch, unquote(Macro.escape(told)))

        assert {:error, why, _state} = Timeless.write(sink(), @host, @node, tick())
        assert why =~ "metrics: 2 samples not stored in :acct: "
        assert why =~ unquote(says)
      end

      test "by #{inspect(told)} does not keep the other signals from being stored" do
        FakeStores.tell(:metrics, :write_batch, unquote(Macro.escape(told)))

        assert {:error, _why, _state} = Timeless.write(sink(), @host, @node, tick())
        assert [ingest: [[%{level: :notice}]]] = FakeStores.calls(:logs)
        assert [ingest: [[%{name: "Ecto"}]]] = FakeStores.calls(:traces)
      end
    end

    test "by exiting from a call says which call it was" do
      FakeStores.tell(:metrics, :write_batch, :exit)
      assert {:error, why, _} = Timeless.write(sink(), @host, @node, tick())
      assert why =~ "in GenServer.call to :fake_metrics"
    end

    test "is named, whichever it is" do
      FakeStores.tell(:logs, :ingest, :exit)
      assert {:error, why, _} = Timeless.write(sink(), @host, @node, tick())
      assert why =~ "logs: 1 record not stored: exited"

      FakeStores.tell(:logs, :ingest, :ok)
      FakeStores.tell(:traces, :ingest, :raise)
      assert {:error, why, _} = Timeless.write(sink(), @host, @node, tick())
      assert why =~ "traces: 1 span not stored: raised RuntimeError"
    end

    test "by never answering is given up on, and the others are still stored" do
      FakeStores.tell(:logs, :ingest, :hang)

      assert {:error, why, _} = Timeless.write(sink(timeout: 0.05), @host, @node, tick())
      assert why =~ "logs: 1 record not stored: no answer in 0.05 s"
      assert [write_batch: _] = FakeStores.calls(:metrics)
      assert [ingest: _] = FakeStores.calls(:traces)
    end

    test "does not take the process that writes with it, nor leave it anything to read" do
      for told <- [:raise, :exit, :break_link, :hang] do
        FakeStores.tell(:traces, :ingest, told)
        assert {:error, _, _} = Timeless.write(sink(timeout: 0.05), @host, @node, tick())
      end

      assert Process.alive?(self())
      refute_received _
    end

    test "by not running is an error, and is not called" do
      state = sink()
      FakeStores.tell(:metrics, :running?, false)

      assert {:error, why, state} = Timeless.write(state, @host, @node, tick())
      assert why =~ "metrics: 2 samples not stored in :acct: the store is not running"
      assert state.lost == %{metrics: 2, logs: 0, traces: 0}
      assert FakeStores.calls(:metrics) == []
      assert [{:logs, :ingest, _}, {:traces, :ingest, _}] = FakeStores.calls()

      assert {:error, why, _} = Timeless.flush(state)
      assert why =~ "metrics: not flushed in :acct: the store is not running"
      assert FakeStores.calls(:metrics) == []
    end

    test "is an error of one line, which does not carry the batch" do
      events = for n <- 1..500, do: %{event() | message: "a record that was not stored #{n}"}
      huge = String.duplicate("the disk is full ", 100)

      for told <- [:exit, :raise, {:error, huge}, {:error, {:rejected, events}}] do
        FakeStores.tell(:logs, :ingest, told)
        assert {:error, why, _} = Timeless.write(sink(), @host, @node, tick(events: events))
        assert why =~ "logs: 500 records not stored: "
        refute why =~ "\n"
        assert String.length(why) < 500
      end
    end

    test "is the first error returned when more than one fails" do
      FakeStores.tell(:logs, :ingest, {:error, :first})
      FakeStores.tell(:traces, :ingest, {:error, :second})

      assert {:error, why, state} = Timeless.write(sink(), @host, @node, tick())
      assert why =~ "logs: 1 record not stored: :first"
      refute why =~ "second"
      assert state.lost == %{metrics: 0, logs: 1, traces: 1}
    end

    test "answers :noop or {:ok, _} and has not failed" do
      FakeStores.tell(:metrics, :write_batch, {:answer, :noop})
      FakeStores.tell(:logs, :ingest, {:answer, {:ok, 1}})
      assert {:ok, _} = Timeless.write(sink(), @host, @node, tick())
    end
  end

  describe "what was lost" do
    test "is counted in ticks, once for a tick however much of it was lost" do
      FakeStores.tell(:metrics, :write_batch, :raise)
      FakeStores.tell(:traces, :ingest, :exit)

      assert {:error, why, state} = Timeless.write(sink(), @host, @node, tick())
      assert state.lost_ticks == 1
      assert why =~ "(1 tick lost since the sink started)"

      assert {:error, why, state} = Timeless.write(state, @host, @node, tick())
      assert state.lost_ticks == 2
      assert why =~ "(2 ticks lost since the sink started)"
    end

    test "is counted in samples, records, and spans" do
      FakeStores.tell(:metrics, :write_batch, :raise)
      FakeStores.tell(:traces, :ingest, :exit)
      spans = [span(), span(span_id: <<3::64>>)]

      assert {:error, _, state} = Timeless.write(sink(), @host, @node, tick(spans: spans))
      assert {:error, _, state} = Timeless.write(state, @host, @node, tick(spans: spans))
      assert state.lost == %{metrics: 4, logs: 0, traces: 4}
    end

    test "is not added to by a tick that was stored" do
      FakeStores.tell(:logs, :ingest, {:error, :busy})
      assert {:error, _, state} = Timeless.write(sink(), @host, @node, tick())

      FakeStores.tell(:logs, :ingest, :ok)
      assert {:ok, state} = Timeless.write(state, @host, @node, tick())
      assert state.lost_ticks == 1
      assert state.lost == %{metrics: 0, logs: 1, traces: 0}
    end

    test "is said by describe" do
      FakeStores.tell(:metrics, :write_batch, :raise)
      FakeStores.tell(:logs, :ingest, :raise)
      assert {:error, _, state} = Timeless.write(sink(), @host, @node, tick())

      assert Timeless.describe(state) =~ "(1 tick lost: 2 samples, 1 record)"
    end

    test "is not kept to be sent again: there is no backlog" do
      FakeStores.tell(:logs, :ingest, {:error, :busy})
      assert {:error, _, state} = Timeless.write(sink(), @host, @node, tick())

      FakeStores.tell(:logs, :ingest, :ok)
      later = tick(events: [%{event() | message: "later"}])
      assert {:ok, _} = Timeless.write(state, @host, @node, later)

      assert [ingest: [[_lost]], ingest: [[%{message: "later"}]]] = FakeStores.calls(:logs)
    end
  end

  describe "flush" do
    test "flushes each store, the metrics store by its name" do
      assert {:ok, _} = Timeless.flush(sink())

      assert FakeStores.calls() == [
               {:metrics, :flush, [:acct]},
               {:logs, :flush, []},
               {:traces, :flush, []}
             ]
    end

    test "flushes the traces library itself, and not what takes its spans" do
      assert {:ok, _} = Timeless.flush(sink(traces_module: FakeTracesLibrary))
      assert [flush: []] = FakeStores.calls(:traces)
    end

    test "leaves a store that has no flush alone" do
      state = sink(logs_module: FakeWithoutFlush, traces_module: FakeWithoutFlush)
      assert state.flushed == [:metrics]

      assert {:ok, _} = Timeless.flush(state)
      assert FakeStores.calls() == [{:metrics, :flush, [:acct]}]
    end

    test "of a store that fails is an error that names the signal, and the others are flushed" do
      for {told, says} <- [
            {{:error, :unavailable}, ":unavailable"},
            {:raise, "raised RuntimeError"},
            {:exit, "exited"}
          ] do
        FakeStores.tell(:metrics, :flush, told)

        assert {:error, why, _} = Timeless.flush(sink())
        assert why =~ "metrics: not flushed in :acct: "
        assert why =~ says
      end

      assert length(FakeStores.calls(:logs)) == 3
      assert length(FakeStores.calls(:traces)) == 3
    end

    test "loses no tick: what was handed over is the store's" do
      FakeStores.tell(:logs, :flush, :raise)
      assert {:error, _, state} = Timeless.flush(sink())
      assert state.lost_ticks == 0
    end
  end

  describe "close" do
    test "flushes, and stops nothing" do
      assert :ok = Timeless.close(sink())

      assert FakeStores.calls() == [
               {:metrics, :flush, [:acct]},
               {:logs, :flush, []},
               {:traces, :flush, []}
             ]
    end

    test "is done though a store cannot be flushed" do
      FakeStores.tell(:metrics, :flush, :exit)
      FakeStores.tell(:logs, :flush, :raise)
      assert :ok = Timeless.close(sink())
      assert [flush: []] = FakeStores.calls(:traces)
    end
  end

  describe "describe" do
    test "is one line that says which stores are written to" do
      {:ok, state} =
        Timeless.init(metrics: :acct, metrics_module: FakeMetrics, logs: false, traces: false)

      assert Timeless.describe(state) ==
               "timeless: metrics in :acct through TimelessBeamAcct.FakeMetrics"
    end

    test "names the library's own modules by the signal alone" do
      # As a sink for the three libraries would be, were they in this node.
      state = %Timeless{
        metrics: :tp_default_timeless,
        traces_ingest: TimelessTraces.StorageEngine
      }

      assert Timeless.describe(state) == "timeless: metrics in :tp_default_timeless, logs, traces"
    end

    test "leaves out a signal that is off" do
      line = Timeless.describe(sink(metrics: false))
      assert line =~ "timeless: logs through"
      assert line =~ ", traces through"
      refute line =~ "metrics"
      refute line =~ "\n"
    end
  end
end
