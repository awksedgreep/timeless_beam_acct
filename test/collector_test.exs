defmodule TimelessBeamAcct.CollectorTest do
  # Not with the others: a collector hears of every process of the node.
  use ExUnit.Case, async: false

  # A VM older than OTP 27 has no such module, and the tests that name it
  # are not run there.
  @compile {:no_warn_undefined, :trace}

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import TimelessBeamAcct.Samples

  alias TimelessBeamAcct.{Identity, Span, Tick, Tracer}

  @moduletag :capture_log

  defp start(given \\ []) do
    name = :"collector_test_#{System.unique_integer([:positive])}"

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
    name
  end

  # Ask for a reading, and take what it produced.
  defp reading(name) do
    flush_ticks()
    :ok = TimelessBeamAcct.tick(name)
    assert_receive {:timeless_beam_acct, :tick, host, node, %Tick{} = tick}, 5_000
    assert host == TimelessBeamAcct.Options.hostname()
    assert node == Atom.to_string(node())
    tick
  end

  # The next tick that has samples in it, or `nil` if none comes in time.
  defp stored(timeout) do
    receive do
      {:timeless_beam_acct, :tick, _, _, %Tick{metrics: %{count: 0}}} -> stored(timeout)
      {:timeless_beam_acct, :tick, _, _, %Tick{} = tick} -> tick
    after
      timeout -> nil
    end
  end

  defp flush_ticks do
    receive do
      {:timeless_beam_acct, _, _, _, _} -> flush_ticks()
      {:timeless_beam_acct, _} -> flush_ticks()
    after
      0 -> :ok
    end
  end

  # Run this to its end, and return its pid once it has ended.
  defp run(fun) do
    {pid, ref} = spawn_monitor(fun)
    assert_receive {:DOWN, ^ref, _, _, _}, 5_000
    pid
  end

  defp record_of(tick, pid) do
    text = Identity.pid_text(pid)
    Enum.find(tick.events, &(&1.fields["kind"] == "exit" and &1.fields["pid"] == text))
  end

  defp span_of(tick, pid) do
    text = Identity.pid_text(pid)
    Enum.find(tick.spans, &(&1.attributes["process.pid"] == text))
  end

  # A reading that has the record of this process, which may be the next:
  # word of an exit is on its way for a moment after the exit.
  defp reading_with(name, pid, tries \\ 50) do
    tick = reading(name)

    cond do
      record_of(tick, pid) -> tick
      tries == 0 -> flunk("no record of #{inspect(pid)}")
      true -> reading_with(name, pid, tries - 1)
    end
  end

  test "a reading is of the node, its applications, its groups, and the collector itself" do
    name = start()
    reading(name)
    tick = reading(name)

    for metric <- [
          "beam_vm_processes",
          "beam_vm_mem_total_bytes",
          "beam_vm_reductions_per_sec",
          "beam_vm_scheduler_util_pct",
          "beam_ets_memory_bytes",
          "beam_dist_nodes",
          "beam_app_processes",
          "beam_app_ets_bytes",
          "beam_group_processes",
          "beam_group_reductions_per_sec",
          "beam_proc_memory_bytes",
          "beam_acct_processes",
          "beam_acct_sweep_seconds",
          "beam_acct_sweep_interval_seconds",
          "beam_acct_reductions_accounted_pct"
        ] do
      assert metric in names(tick.metrics), "no #{metric}"
    end

    assert value(tick.metrics, "beam_app_processes", app: "kernel") > 5
    assert value(tick.metrics, "beam_acct_sweep_interval_seconds") == 3600.0
    # Never in the labels: the sink gives them to everything.
    for {_, labels, _} <- TimelessBeamAcct.Batch.samples(tick.metrics) do
      refute List.keymember?(labels, "host", 0)
      refute List.keymember?(labels, "node", 0)
    end
  end

  test "the first reading stores no samples" do
    name = :"collector_test_#{System.unique_integer([:positive])}"

    start_supervised!(
      {TimelessBeamAcct,
       name: name, sink: {:forward, to: self()}, interval: 3600, process_interval: 3600}
    )

    # It is taken when the collector starts, and has nothing in it to write.
    assert stored(200) == nil
  end

  describe "with word of each exit" do
    @describetag skip: if(Tracer.available?(), do: false, else: "this VM has no trace sessions")

    test "every process that ends has a record, however briefly it lived" do
      name = start()
      reading(name)

      normal = run(fn -> :ok end)
      custom = run(fn -> exit(:custom) end)
      crashed = run(fn -> raise "boom" end)
      killed = run(fn -> Process.exit(self(), :kill) end)

      tick = reading_with(name, killed)

      assert %{level: :info, fields: %{"status" => "normal", "source" => "traced"}} =
               record_of(tick, normal)

      assert %{level: :notice, fields: %{"status" => "custom"}} = record_of(tick, custom)

      assert %{level: :error, fields: %{"status" => "RuntimeError", "crashed" => true}} =
               record_of(tick, crashed)

      assert %{level: :warning, fields: %{"status" => "killed"}} = record_of(tick, killed)

      record = record_of(tick, normal)
      assert record.fields["parent"] == Identity.pid_text(self())
      assert record.fields["service"] =~ "fn in TimelessBeamAcct.CollectorTest."
      assert record.fields["elapsed_seconds"] >= 0
      assert record.fields["elapsed_seconds"] < 1
      assert record.message =~ ~r/exited normal after \d+(µs|ms)\z/

      # In the order they ended.
      times = Enum.map(tick.events, & &1.ts_us)
      assert times == Enum.sort(times)
    end

    test "a process that lived to a sweep has the figures of the sweep" do
      name = start()
      reading(name)

      {pid, ref} = spawn_monitor(fn -> receive(do: (:stop -> Enum.reduce(1..10, 0, &+/2))) end)
      reading(name)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, _, _, _}

      record = name |> reading_with(pid) |> record_of(pid)
      assert record.fields["reductions"] >= 0
      assert record.fields["peak_memory_bytes"] > 0
      assert record.fields["figures_age_seconds"] >= 0
      assert record.message =~ "peak memory"
    end

    test "a job is a trace: what a process started is under it" do
      name = start()
      reading(name)
      test = self()

      root =
        run(fn ->
          children =
            for _ <- 1..3 do
              {pid, ref} = spawn_monitor(fn -> :ok end)
              assert_receive {:DOWN, ^ref, _, _, _}
              pid
            end

          send(test, {:children, children})
        end)

      assert_receive {:children, children}
      tick = reading_with(name, root)

      under = span_of(tick, root)
      assert %Span{ok: true, service: "none"} = under

      for child <- children do
        span = span_of(tick, child)
        assert span.trace_id == under.trace_id
        assert span.parent_span_id == under.span_id
        assert span.start_ns >= under.start_ns
      end

      # The record of a process says which span is its.
      assert record_of(tick, root).fields["span_id"] == Span.hex(under.span_id)
      assert record_of(tick, root).fields["trace_id"] == Span.hex(under.trace_id)
    end

    test "a task is under the process that asked for it, whoever started it" do
      name = start()
      {:ok, supervisor} = Task.Supervisor.start_link()
      reading(name)
      test = self()

      asker =
        run(fn ->
          task = Task.Supervisor.async(supervisor, fn -> :done end)
          send(test, {:task, task.pid})
          Task.await(task)
        end)

      assert_receive {:task, task}
      wait_until(fn -> not Process.alive?(task) end)
      tick = reading_with(name, asker)
      tick = if span_of(tick, task), do: tick, else: reading_with(name, task)

      assert record_of(tick, task).fields["parent"] == Identity.pid_text(supervisor)
      assert record_of(tick, task).fields["caller"] == Identity.pid_text(asker)
      # It is called by what it was given to do, which it was sent once
      # it was running.
      assert record_of(tick, task).fields["service"] =~ "fn in TimelessBeamAcct.CollectorTest."
      assert span_of(tick, task).parent_span_id == span_of(tick, asker).span_id
    end

    test "only the failures have records, if that is what was asked for" do
      name = start(records: :abnormal)
      reading(name)

      normal = run(fn -> :ok end)
      custom = run(fn -> exit(:custom) end)
      tick = reading_with(name, custom)

      assert record_of(tick, normal) == nil
      # Its span is kept: a tree with only its failures in it is not a tree.
      assert span_of(tick, normal)
    end

    test "only so many have records, of those that ended as they were meant to and of those that did not" do
      name = start(max_records: 5)
      reading(name)

      ordinary = for _ <- 1..40, do: run(fn -> :ok end)
      failed = for _ <- 1..10, do: run(fn -> exit(:custom) end)

      # Word of the last of them has to have arrived.
      handle = Tracer.handle(name)
      before = Tracer.counts(handle).exits
      wait_until(fn -> Tracer.last(handle) != nil and Tracer.counts(handle).exits >= before end)
      Process.sleep(100)
      tick = reading(name)

      assert Enum.count(ordinary, &record_of(tick, &1)) <= 5
      assert Enum.count(failed, &record_of(tick, &1)) == 5
      # A span for each that has a record, and for no other.
      assert Enum.count(failed, &span_of(tick, &1)) == 5

      status = TimelessBeamAcct.status(name)
      assert status.dropped.records >= 40
      assert value(reading(name).metrics, "beam_acct_records_dropped") >= 40

      # All of them are in the totals.
      group = record_of(tick, Enum.find(failed, &record_of(tick, &1))).fields["service"]
      assert value(tick.metrics, "beam_group_exits_per_sec", group: group) > 0
    end

    test "what the tracer has counted is reported" do
      name = start()
      reading(name)
      for _ <- 1..20, do: run(fn -> :ok end)
      tick = reading(name)

      assert value(tick.metrics, "beam_acct_trace_listening") == 1
      assert value(tick.metrics, "beam_acct_spawns") >= 20
      assert value(tick.metrics, "beam_acct_exits") >= 20
      assert value(tick.metrics, "beam_vm_spawns_per_sec") > 0
      assert value(tick.metrics, "beam_vm_exits_per_sec") > 0
      assert value(tick.metrics, "beam_acct_trace_suspensions") == 0
    end

    @tag skip:
           if(Tracer.remarks?(),
             do: false,
             else: "a trace session of this VM has no system monitor"
           )
    test "what the VM remarks on is recorded, of the process it is remarked of" do
      name = start(anomalies: true, large_heap: 1024 * 1024)
      reading(name)

      {pid, ref} =
        spawn_monitor(fn ->
          list = Enum.to_list(1..400_000)
          receive(do: (:stop -> length(list)))
        end)

      wait_until(fn -> TimelessBeamAcct.status(name) != nil end)
      Process.sleep(50)
      tick = reading(name)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, _, _, _}

      text = Identity.pid_text(pid)

      assert [remark] =
               Enum.filter(
                 tick.events,
                 &(&1.fields["kind"] == "large_heap" and &1.fields["pid"] == text)
               )

      assert %{level: :warning, fields: %{"unit" => "bytes"}} = remark
      assert remark.fields["value"] >= 1024 * 1024
      assert remark.fields["service"] =~ "fn in TimelessBeamAcct.CollectorTest."
      assert remark.message =~ "has a heap of"
    end
  end

  describe "without word of each exit" do
    test "a process that ends is noticed gone, if it lived to a sweep" do
      name = start(exits: false)
      {pid, ref} = spawn_monitor(fn -> receive(do: (:stop -> :ok)) end)
      reading(name)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, _, _, _}

      tick = reading(name)
      record = record_of(tick, pid)

      assert %{level: :info, fields: %{"source" => "sampled", "status" => "unknown"}} = record
      assert record.fields["seen_seconds"] >= 0
      assert record.message =~ "gone after at least"
      assert tick.spans == []
      assert value(tick.metrics, "beam_acct_trace_listening") == nil
      assert TimelessBeamAcct.status(name).exits == :not_asked_for
    end
  end

  describe "on a VM that has no trace sessions" do
    @describetag skip: if(Tracer.available?(), do: "this VM has trace sessions", else: false)

    test "a collector told to hear of exits starts, and says that it cannot" do
      name = start(exits: true, descriptions: true, anomalies: true, traces: true)
      reading(name)

      assert TimelessBeamAcct.status(name).exits == :unavailable
      assert TimelessBeamAcct.status(name).tracer == nil
      assert Tracer.handle(name) == nil
    end

    test "a process that ends is noticed gone, if it lived to a sweep, and has no span" do
      name = start(exits: true, traces: true)
      {pid, ref} = spawn_monitor(fn -> receive(do: (:stop -> exit(:custom))) end)
      reading(name)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, _, _, _}

      tick = reading(name)
      record = record_of(tick, pid)

      # Why it ended was said to no one.
      assert %{level: :info, fields: %{"source" => "sampled", "status" => "unknown"}} = record
      assert tick.spans == []
      assert TimelessBeamAcct.spans(name) == []
      assert value(tick.metrics, "beam_acct_trace_listening") == nil
    end

    test "a process shorter than a sweep is not seen" do
      name = start()
      reading(name)
      pid = run(fn -> exit(:custom) end)

      assert record_of(reading(name), pid) == nil
      assert record_of(reading(name), pid) == nil
    end
  end

  describe "from a shell on the node" do
    test "the collector says how it is doing" do
      name = start()
      reading(name)
      status = TimelessBeamAcct.status(name)

      assert status.options.name == name
      assert status.sweep.processes > 10
      assert status.sweep.seconds > 0
      assert status.sweep.interval == 3600.0
      assert status.vm.processes > 10
      assert status.writer.sink =~ "forward"
      assert status.writer.written >= 1
      assert TimelessBeamAcct.running?(name)

      assert TimelessBeamAcct.status(:no_such_collector) == nil
      refute TimelessBeamAcct.running?(:no_such_collector)
    end

    test "top is of the processes as of the last sweep" do
      name = start()
      registered = :"collector_top_#{System.unique_integer([:positive])}"
      {:ok, agent} = Agent.start_link(fn -> 1 end, name: registered)
      reading(name)
      reading(name)

      printed = capture_io(fn -> assert TimelessBeamAcct.top(name: name, n: 1000) == :ok end)
      assert printed =~ ~r/\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  #{node()}  \(\d+ processes\)\n/
      assert printed =~ "PID  APP"
      assert printed =~ "#{Identity.pid_text(agent)}"
      assert printed =~ "#{registered}"

      snapshot = TimelessBeamAcct.snapshot(name)
      assert snapshot.vm.processes > 10
      assert Enum.any?(snapshot.processes, &(&1.name == Atom.to_string(registered)))
      Agent.stop(agent)
    end

    @tag skip: if(Tracer.available?(), do: false, else: "this VM has no trace sessions")
    test "exits and trees are of what is kept in memory" do
      name = start()
      reading(name)
      failed = run(fn -> exit(:custom) end)
      reading_with(name, failed)

      text = Identity.pid_text(failed)
      assert [record] = TimelessBeamAcct.records(name: name, status: "custom")
      assert record.fields["pid"] == text
      assert Enum.any?(TimelessBeamAcct.spans(name), &(&1.attributes["process.pid"] == text))

      printed = capture_io(fn -> TimelessBeamAcct.exits(name: name, failed: true) end)
      assert printed =~ "ENDED"
      assert printed =~ text
      assert printed =~ "custom"

      printed = capture_io(fn -> TimelessBeamAcct.exits(name: name, summary: true, by: :app) end)
      assert printed =~ "COUNT  FAILED"

      printed = capture_io(fn -> TimelessBeamAcct.trees(name: name, failed: true) end)
      assert printed =~ "[exited custom]"
    end

    test "diagnostics are what a report of a problem should have in it" do
      name = start(sink: {:forward, to: self()}, min_age: 5, max_records: 77)
      reading(name)

      said = TimelessBeamAcct.diagnosed(name: name)

      assert said =~ ~r/\Atimeless_beam_acct #{Regex.escape(TimelessBeamAcct.version())}\n/
      assert said =~ "Elixir #{System.version()}, OTP #{System.otp_release()}"
      assert said =~ ~r/^node #{node()}, up /m
      assert said =~ ~r/^collector +running: a sweep of/m
      # What it was told, and nothing of what it was not.
      assert said =~ "told\n"
      assert said =~ "  max_records: 77\n"
      assert said =~ "  min_age: 5.0\n"
      refute said =~ "max_groups"
      assert said =~ ~r/^let go +0 records, 0 ticks$/m
      assert said =~ ~r/^writer +\d+ ticks written, 0 failed$/m

      printed = capture_io(fn -> assert TimelessBeamAcct.diagnostics(name: name) == :ok end)
      assert printed =~ "  max_records: 77\n"
      assert String.split(printed, "\n") |> length() == String.split(said, "\n") |> length()
    end

    test "a token is not among what is printed" do
      name =
        start(
          sink:
            {:http,
             token: "a-secret",
             metrics_url: "http://127.0.0.1:1",
             logs_url: "http://127.0.0.1:1",
             traces_url: "http://127.0.0.1:1",
             timeout: 0.2}
        )

      said = TimelessBeamAcct.diagnosed(name: name)
      refute said =~ "a-secret"
      assert said =~ ~s(token: "(given\)")
      assert said =~ "http://127.0.0.1:1"
    end

    test "diagnostics of a node with no collector say so" do
      # Told where the planes are, which is nowhere, so that those running
      # on this machine are not asked whether they are there.
      nowhere = "http://127.0.0.1:1"

      said =
        TimelessBeamAcct.diagnosed(
          name: :no_such_collector,
          metrics_url: nowhere,
          logs_url: nowhere,
          traces_url: nowhere
        )

      assert said =~ "timeless_beam_acct "
      assert said =~ "#{nowhere}  connection refused"
      assert said =~ ~r/^collector +not running$/m
      refute said =~ "told"
    end

    test "check says what the node lets a collector see" do
      name = start()
      reading(name)

      checked = Map.new(TimelessBeamAcct.checked(name: name))
      assert checked["processes"] =~ ~r/\A\d+ of \d+\z/
      assert checked["collector"] =~ "running: a sweep of"
      assert checked["sink"] =~ "forward"
      assert checked["scheduler wall time"] == "on"

      if Tracer.available?() do
        assert checked["trace sessions"] == "available"
        assert checked["word of each exit"] =~ "heard: "
      else
        assert checked["trace sessions"] =~ "unavailable: needs OTP 27"
      end

      printed = capture_io(fn -> assert TimelessBeamAcct.check(name: name) == :ok end)
      assert printed =~ ~r/^processes +\d+ of \d+$/m

      # Of a collector that is not running. It is told where the planes
      # are, which is nowhere: told nothing, it would ask the planes that
      # are running on this machine whether they are there.
      nowhere = "http://127.0.0.1:1"

      checked =
        Map.new(
          TimelessBeamAcct.checked(
            name: :no_such_collector,
            metrics_url: nowhere,
            logs_url: nowhere,
            traces_url: nowhere
          )
        )

      assert checked["collector"] == "not running"
      assert checked["metrics plane"] == "#{nowhere}  connection refused"

      # A trace session has a system monitor a release after there were
      # trace sessions.
      if Tracer.remarks?() do
        assert checked["what the VM remarks on"] == "heard"
      else
        assert checked["what the VM remarks on"] =~ "unavailable: needs OTP 28, and this is OTP "
      end
    end
  end

  describe "stopping" do
    @tag skip: if(Tracer.available?(), do: false, else: "this VM has no trace sessions")
    test "what ended since the last sweep is accounted, and the sink is flushed and closed" do
      name = start()
      reading(name)
      last = run(fn -> exit(:last_words) end)
      # Word of it has to have arrived, and no reading is asked for.
      handle = Tracer.handle(name)
      wait_until(fn -> Tracer.counts(handle).exits > 0 end)
      Process.sleep(50)
      flush_ticks()

      stop_supervised!(name)

      assert_receive {:timeless_beam_acct, :tick, _, _, %Tick{metrics: %{count: 0}} = tick}
      assert %{fields: %{"status" => "last_words"}} = record_of(tick, last)
      assert_receive {:timeless_beam_acct, :flush}
      assert_receive {:timeless_beam_acct, :close}

      refute TimelessBeamAcct.running?(name)
      assert TimelessBeamAcct.status(name) == nil
    end

    test "leaves the VM as it was found" do
      before = :erlang.statistics(:scheduler_wall_time)
      name = start(msacc: true)
      reading(name)
      assert :erlang.statistics(:scheduler_wall_time) != :undefined
      stop_supervised!(name)

      if before == :undefined do
        wait_until(fn -> :erlang.statistics(:scheduler_wall_time) == :undefined end)
      end

      if Tracer.available?() do
        session = TimelessBeamAcct.Options.name(name, :Session)
        refute Enum.any?(:trace.session_info(:all), &match?({^session, _}, &1))
      end
    end
  end

  describe "what is wrong" do
    test "with an option is refused before anything is started" do
      assert_raise ArgumentError, ~r/unknown option :intervl/, fn ->
        TimelessBeamAcct.start_link(intervl: 5)
      end
    end

    test "with the sink is refused when it is started" do
      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          assert {:error, reason} =
                   TimelessBeamAcct.start_link(name: :collector_test_bad_sink, sink: :forward)

          assert inspect(reason) =~ "sink"
        end)

      assert is_binary(log)
      refute TimelessBeamAcct.running?(:collector_test_bad_sink)
    end

    test "with a write does not stop the collector" do
      name = start(sink: {:forward, to: :no_such_process_is_registered})

      log =
        capture_log(fn ->
          :ok = TimelessBeamAcct.tick(name)
          :ok = TimelessBeamAcct.tick(name)
          :ok = TimelessBeamAcct.flush(name)
        end)

      assert log =~ "write failed"
      status = TimelessBeamAcct.status(name)
      assert status.writer.failing
      assert status.writer.failed >= 2
      assert TimelessBeamAcct.running?(name)
    end
  end

  describe "on its own schedule" do
    test "readings land on round times" do
      name = :"collector_test_#{System.unique_integer([:positive])}"

      start_supervised!(
        {TimelessBeamAcct,
         name: name, sink: {:forward, to: self()}, interval: 1, process_interval: 1, exits: false}
      )

      assert %Tick{metrics: first} = stored(3_000)
      assert %Tick{metrics: second} = stored(3_000)

      assert second.ts == first.ts + 1
      # Taken when it was due, to within what a timer allows.
      assert_in_delta System.os_time(:millisecond) / 1000, second.ts, 0.5
      assert value(second, "beam_vm_processes") > 10
      assert value(second, "beam_group_reductions_per_sec", group: "init") != nil
    end
  end
end
