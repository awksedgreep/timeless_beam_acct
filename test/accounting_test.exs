defmodule TimelessBeamAcct.AccountingTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.{Accounting, Ended, Ending, Event, Span}

  @levels %{normal: :info, abnormal: :notice, killed: :warning, crashed: :error}
  @ended 1_790_000_002_500_000

  defp ended(changes \\ []) do
    struct!(
      %Ended{
        pid: "<0.512.0>",
        group: "MyApp.Worker",
        path: "MyApp.Worker.init/1",
        app: "my_app",
        parent: "<0.300.0>",
        parent_group: "MyApp.Supervisor",
        since: @ended - 2_500_000,
        born: true,
        ended: @ended,
        ending: Ending.of(:normal),
        source: :traced,
        figures: %{
          reductions: 12_400,
          memory: 2_000_000,
          peak_memory: 2_202_009,
          queue: 3,
          at: @ended - 1_000_000
        }
      },
      changes
    )
  end

  test "a record says what ended, how, after how long, and what it had used" do
    event = Accounting.exit_event(ended(), @levels)

    assert %Event{ts_us: @ended, level: :info} = event

    assert event.message ==
             "MyApp.Worker<0.512.0> exited normal after 2.5s, 12.4k reductions, peak memory 2.1 MiB"

    assert event.fields == %{
             "kind" => "exit",
             "source" => "traced",
             "service" => "MyApp.Worker",
             "status" => "normal",
             "path" => "MyApp.Worker.init/1",
             "pid" => "<0.512.0>",
             "app" => "my_app",
             "parent" => "<0.300.0>",
             "parent_name" => "MyApp.Supervisor",
             "started" => 1_790_000_000.0,
             "elapsed_seconds" => 2.5,
             "reductions" => 12_400,
             "memory_bytes" => 2_000_000,
             "peak_memory_bytes" => 2_202_009,
             "message_queue_len" => 3,
             "figures_age_seconds" => 1.0
           }
  end

  test "a registered process is called by its name" do
    event = Accounting.exit_event(ended(name: "the_worker", group: "the_worker"), @levels)
    assert event.message =~ ~r/\Athe_worker<0\.512\.0> /
    assert event.fields["name"] == "the_worker"
  end

  test "a process no sweep saw has a record with no figures" do
    event = Accounting.exit_event(ended(figures: nil, since: @ended - 1_000), @levels)
    assert event.message == "MyApp.Worker<0.512.0> exited normal after 1ms"
    refute Map.has_key?(event.fields, "reductions")
    refute Map.has_key?(event.fields, "peak_memory_bytes")
    assert event.fields["elapsed_seconds"] == 0.001
  end

  test "a process that was already running lived longer than it was known of" do
    event = Accounting.exit_event(ended(born: false, since: @ended - 40_000_000), @levels)
    assert event.message =~ "after at least 40.0s"
    assert event.fields["seen_seconds"] == 40.0
    refute Map.has_key?(event.fields, "started")
    refute Map.has_key?(event.fields, "elapsed_seconds")
  end

  test "the level of a record is a judgement about the host" do
    stack = [{My, :fun, 2, [file: ~c"my.ex", line: 3]}]

    for {reason, level} <- [
          {:normal, :info},
          {:shutdown, :info},
          {{:shutdown, :closed}, :info},
          {{:timeout, :call}, :notice},
          {:custom, :notice},
          {:killed, :warning},
          {{:badarg, stack}, :error},
          {{%RuntimeError{message: "x"}, stack}, :error}
        ] do
      event = Accounting.exit_event(ended(ending: Ending.of(reason)), @levels)
      assert event.level == level, "#{inspect(reason)} was #{event.level}"
    end

    quiet = %{@levels | crashed: :info}
    assert Accounting.exit_event(ended(ending: Ending.of({:badarg, stack})), quiet).level == :info
  end

  test "a crash says what was raised, and where" do
    stack = [{My, :fun, 2, [file: ~c"lib/my.ex", line: 3]}]
    ending = Ending.of({%RuntimeError{message: "boom"}, stack})
    event = Accounting.exit_event(ended(ending: ending), @levels)

    assert event.message =~ "MyApp.Worker<0.512.0> crashed: RuntimeError after 2.5s"
    assert event.fields["status"] == "RuntimeError"
    assert event.fields["reason"] == "RuntimeError: boom"
    assert event.fields["crashed"] == true
    assert event.fields["at"] == "lib/my.ex:3: My.fun/2"
  end

  test "a process noticed gone has a record that says so" do
    event = Accounting.exit_event(ended(ending: Ending.unknown(), source: :sampled), @levels)
    assert event.level == :info
    assert event.message =~ "MyApp.Worker<0.512.0> gone after 2.5s"
    assert event.fields["source"] == "sampled"
    assert event.fields["status"] == "unknown"
  end

  describe "spans" do
    @place %{trace_id: <<1::128>>, span_id: <<2::64>>, parent_span_id: <<3::64>>}

    test "a process with no place in a trace has no span" do
      assert Accounting.span(ended()) == nil
    end

    test "a span has the figures of the record" do
      process = ended(place: @place, caller: "<0.400.0>")
      span = Accounting.span(process)
      event = Accounting.exit_event(process, @levels)

      assert %Span{name: "MyApp.Worker", service: "my_app", ok: true, ending: "exited normal"} =
               span

      assert span.trace_id == @place.trace_id
      assert span.span_id == @place.span_id
      assert span.parent_span_id == @place.parent_span_id
      assert span.start_ns == 1_790_000_000_000_000_000
      assert span.duration_ns == 2_500_000_000

      assert span.attributes == %{
               "process.pid" => "<0.512.0>",
               "process.parent_pid" => "<0.300.0>",
               "process.caller_pid" => "<0.400.0>",
               "process.app" => "my_app",
               "process.initial_call" => "MyApp.Worker.init/1",
               "process.exit.status" => "normal",
               "process.source" => "traced",
               "process.start_known" => true,
               "process.reductions" => 12_400,
               "process.peak_memory_bytes" => 2_202_009
             }

      assert event.fields["trace_id"] == "00000000000000000000000000000001"
      assert event.fields["span_id"] == "0000000000000002"
    end

    test "a span says whether the process ended as it was meant to" do
      assert Accounting.span(ended(place: @place, ending: Ending.of(:killed))).ok == false
      assert Accounting.span(ended(place: @place, ending: Ending.of(:killed))).ending == "killed"
      assert Accounting.span(ended(place: @place, ending: Ending.unknown())).ok == nil

      assert Span.status(Accounting.span(ended(place: @place, ending: Ending.unknown()))) ==
               :unset
    end
  end

  describe "remarks" do
    defp remark(changes) do
      Map.merge(
        %{
          kind: :long_gc,
          at: @ended,
          pid: "<0.512.0>",
          group: "MyApp.Worker",
          name: nil,
          path: "MyApp.Worker.init/1",
          app: "my_app",
          value: 120,
          detail: nil
        },
        Map.new(changes)
      )
    end

    test "what makes a node slow is a notice" do
      event = Accounting.remark_event(remark(kind: :long_gc, value: 120))
      assert event.level == :notice
      assert event.message == "MyApp.Worker<0.512.0> took 120ms to collect garbage"

      assert event.fields == %{
               "kind" => "long_gc",
               "source" => "monitor",
               "service" => "MyApp.Worker",
               "status" => "long_gc",
               "pid" => "<0.512.0>",
               "app" => "my_app",
               "path" => "MyApp.Worker.init/1",
               "value" => 120,
               "unit" => "ms"
             }

      event = Accounting.remark_event(remark(kind: :long_schedule, value: 1500))
      assert event.message == "MyApp.Worker<0.512.0> ran for 1.5s without yielding"

      event = Accounting.remark_event(remark(kind: :busy_port, value: nil, detail: "#Port<0.5>"))
      assert event.level == :notice
      assert event.message == "MyApp.Worker<0.512.0> is held up by a busy port, #Port<0.5>"
    end

    test "what a node runs out of memory from is a warning" do
      event = Accounting.remark_event(remark(kind: :large_heap, value: 300 * 1024 * 1024))
      assert event.level == :warning
      assert event.message == "MyApp.Worker<0.512.0> has a heap of 300 MiB"
      assert event.fields["unit"] == "bytes"

      event = Accounting.remark_event(remark(kind: :long_message_queue, value: 10_000))
      assert event.level == :warning
      assert event.message == "MyApp.Worker<0.512.0> has a long queue: 10.0k waiting"

      event =
        Accounting.remark_event(remark(kind: :long_message_queue, value: 12, detail: "cleared"))

      assert event.message == "MyApp.Worker<0.512.0> has worked its queue down: 12 waiting"
    end
  end
end
