defmodule TimelessBeamAcct.Collect.VmTest do
  # Not async: microstate accounting is one switch for the whole VM.
  use ExUnit.Case, async: false

  alias TimelessBeamAcct.{Batch, Options}
  alias TimelessBeamAcct.Collect.Vm

  @rates ~w(
    beam_vm_cpu_pct beam_vm_reductions_per_sec beam_vm_context_switches_per_sec
    beam_vm_gcs_per_sec beam_vm_gc_reclaimed_bytes_per_sec
    beam_vm_io_in_bytes_per_sec beam_vm_io_out_bytes_per_sec
  )

  # A VM with two schedulers, two dirty CPU schedulers, and two dirty I/O
  # schedulers, that has done nothing.
  defp reading(changes) do
    Map.merge(
      %{
        schedulers: 2,
        schedulers_online: 2,
        dirty_cpu_schedulers: 2,
        dirty_cpu_schedulers_online: 2,
        scheduler_wall_time: nil,
        run_queues: [0, 0, 0, 0],
        runtime_ms: 0,
        reductions: 0,
        context_switches: 0,
        gcs: 0,
        gc_bytes: 0,
        io_in_bytes: 0,
        io_out_bytes: 0,
        memory: nil,
        processes: {0, 1000},
        ports: {0, 1000},
        atoms: {0, 1000},
        ets_tables: {0, 1000},
        persistent_terms: 0,
        persistent_term_bytes: 0,
        uptime_ms: 0,
        msacc: nil
      },
      Map.new(changes)
    )
  end

  defp report(previous, reading, seconds, opts \\ []) do
    Batch.new(0) |> Vm.report(previous, reading, seconds, opts) |> by_series()
  end

  # The samples by `{name, labels}`, or by name alone if there are no labels.
  defp by_series(%Batch{} = batch) do
    samples = Batch.samples(batch)
    series = Enum.map(samples, fn {name, labels, _} -> {name, labels} end)
    assert series == Enum.uniq(series), "a series was reported twice"

    Map.new(samples, fn
      {name, [], value} -> {name, value}
      {name, labels, value} -> {{name, labels}, value}
    end)
  end

  defp scheduler(samples, id),
    do: samples[{"beam_vm_scheduler_util_pct", [{"scheduler", to_string(id)}]}]

  defp mono, do: System.monotonic_time(:microsecond) / 1_000_000

  describe "from readings written by hand" do
    test "the first reading gives levels and no rates" do
      times = for id <- 1..6, do: {id, 10, 100}

      samples =
        report(nil, reading(scheduler_wall_time: times, msacc: %{sleep: 5}, reductions: 9), nil)

      assert samples["beam_vm_run_queue"] == 0
      assert samples["beam_vm_processes"] == 0
      assert samples["beam_vm_uptime_seconds"] == 0.0

      for name <- @rates, do: refute(is_map_key(samples, name), "#{name} on a first reading")

      refute Enum.any?(Map.keys(samples), fn
               {name, _labels} -> String.contains?(name, "util_pct")
               name -> String.contains?(name, "util_pct") or String.contains?(name, "msacc")
             end)
    end

    test "a rate is what a counter rose by, over the time between two readings" do
      before =
        reading(
          reductions: 1_000,
          context_switches: 10,
          gcs: 4,
          gc_bytes: 8_000,
          io_in_bytes: 100,
          io_out_bytes: 0
        )

      now =
        reading(
          reductions: 3_000,
          context_switches: 30,
          gcs: 5,
          gc_bytes: 88_000,
          io_in_bytes: 100,
          io_out_bytes: 1_024
        )

      samples = report(before, now, 2.0)

      assert samples["beam_vm_reductions_per_sec"] == 1000.0
      assert samples["beam_vm_context_switches_per_sec"] == 10.0
      assert samples["beam_vm_gcs_per_sec"] == 0.5
      assert samples["beam_vm_gc_reclaimed_bytes_per_sec"] == 40_000.0
      assert samples["beam_vm_io_in_bytes_per_sec"] == 0.0
      assert samples["beam_vm_io_out_bytes_per_sec"] == 512.0
    end

    test "CPU is a share of one CPU, and passes 100 when several threads are busy" do
      # Three seconds of CPU in two seconds.
      samples = report(reading(runtime_ms: 500), reading(runtime_ms: 3_500), 2.0)
      assert samples["beam_vm_cpu_pct"] == 150.0
    end

    test "a counter that went backwards leaves a gap, and the others are still reported" do
      samples = report(reading(reductions: 500, gcs: 1), reading(reductions: 20, gcs: 3), 1.0)
      refute is_map_key(samples, "beam_vm_reductions_per_sec")
      assert samples["beam_vm_gcs_per_sec"] == 2.0
    end

    test "with no time between two readings there are levels and no rates" do
      times = for id <- 1..6, do: {id, 10, 100}
      before = reading(scheduler_wall_time: times)
      now = reading(scheduler_wall_time: times, reductions: 50, processes: {7, 1000})

      for seconds <- [0, 0.0, -1.0, nil] do
        samples = report(before, now, seconds)
        assert samples["beam_vm_processes"] == 7
        for name <- @rates, do: refute(is_map_key(samples, name))
        refute is_map_key(samples, {"beam_vm_scheduler_util_pct", [{"scheduler", "all"}]})
      end
    end

    test "a scheduler's utilisation is the share of the time that it was active" do
      before = for id <- 1..6, do: {id, 1_000, 10_000}

      now = [
        # Given out of order, as the VM gives them.
        {2, 1_000 + 750, 11_000},
        {1, 1_000 + 250, 11_000},
        {3, 1_000 + 100, 11_000},
        {4, 1_000 + 300, 11_000},
        {5, 1_000, 11_000},
        {6, 1_000 + 1_000, 11_000}
      ]

      samples =
        report(reading(scheduler_wall_time: before), reading(scheduler_wall_time: now), 1.0)

      assert scheduler(samples, 1) == 25.0
      assert scheduler(samples, 2) == 75.0
      assert scheduler(samples, :all) == 50.0
      # Schedulers 3 and 4 are the dirty CPU schedulers, 5 and 6 dirty I/O.
      assert samples["beam_vm_dirty_cpu_util_pct"] == 20.0
      assert samples["beam_vm_dirty_io_util_pct"] == 50.0
      refute scheduler(samples, 3)
    end

    test "all schedulers together are weighed by the time each was measured over" do
      before = [{1, 0, 0}, {2, 0, 0}]
      now = [{1, 300, 300}, {2, 0, 100}]

      samples =
        report(
          reading(scheduler_wall_time: before, dirty_cpu_schedulers: 0),
          reading(scheduler_wall_time: now, dirty_cpu_schedulers: 0),
          1.0
        )

      assert scheduler(samples, :all) == 75.0
    end

    test "a scheduler that is offline is not reported, and is not part of the whole" do
      layout = [
        schedulers: 4,
        schedulers_online: 2,
        dirty_cpu_schedulers: 2,
        dirty_cpu_schedulers_online: 1
      ]

      before = for id <- 1..7, do: {id, 0, 0}

      now = [
        {1, 600, 1_000},
        {2, 400, 1_000},
        # Offline: time passes for them, and they do nothing in it.
        {3, 0, 1_000},
        {4, 0, 1_000},
        # Dirty CPU, the second of them offline.
        {5, 900, 1_000},
        {6, 0, 1_000},
        # Dirty I/O.
        {7, 100, 1_000}
      ]

      samples =
        report(
          reading([scheduler_wall_time: before] ++ layout),
          reading([scheduler_wall_time: now] ++ layout),
          1.0
        )

      assert scheduler(samples, :all) == 50.0
      assert scheduler(samples, 1) == 60.0
      assert scheduler(samples, 2) == 40.0
      refute scheduler(samples, 3)
      refute scheduler(samples, 4)
      assert samples["beam_vm_dirty_cpu_util_pct"] == 90.0
      assert samples["beam_vm_dirty_io_util_pct"] == 10.0
    end

    test "each scheduler is reported only if that was asked for" do
      before = for id <- 1..6, do: {id, 0, 0}
      now = for id <- 1..6, do: {id, 10, 100}
      before = reading(scheduler_wall_time: before)
      now = reading(scheduler_wall_time: now)

      samples = report(before, now, 1.0, per_scheduler: false)
      assert scheduler(samples, :all) == 10.0
      assert samples["beam_vm_dirty_cpu_util_pct"] == 10.0
      refute scheduler(samples, 1)

      assert report(before, now, 1.0) |> scheduler(1) == 10.0
    end

    test "nothing is said of schedulers while the VM is not keeping their times" do
      times = for id <- 1..6, do: {id, 10, 100}

      for {before, now} <- [{nil, times}, {times, nil}, {nil, nil}] do
        samples =
          report(
            reading(scheduler_wall_time: before),
            reading(scheduler_wall_time: now, reductions: 10),
            1.0
          )

        refute scheduler(samples, :all)
        refute is_map_key(samples, "beam_vm_dirty_cpu_util_pct")
        assert samples["beam_vm_reductions_per_sec"] == 10.0
      end
    end

    test "a scheduler whose times started again is left out" do
      before = [{1, 5_000, 9_000}, {2, 100, 9_000}] ++ for(id <- 3..6, do: {id, 0, 9_000})
      now = [{1, 10, 50}, {2, 600, 10_000}] ++ for(id <- 3..6, do: {id, 0, 10_000})

      samples =
        report(reading(scheduler_wall_time: before), reading(scheduler_wall_time: now), 1.0)

      refute scheduler(samples, 1)
      assert scheduler(samples, 2) == 50.0
      assert scheduler(samples, :all) == 50.0
    end

    test "the run queues are the normal ones together, then dirty CPU, then dirty I/O" do
      samples = report(nil, reading(run_queues: [1, 0, 4, 2, 7, 3]), nil)
      assert samples["beam_vm_run_queue"] == 7
      assert samples["beam_vm_run_queue_dirty_cpu"] == 7
      assert samples["beam_vm_run_queue_dirty_io"] == 3
    end

    test "memory is reported by kind" do
      memory = [
        total: 900,
        processes: 400,
        processes_used: 390,
        system: 500,
        atom: 50,
        atom_used: 45,
        binary: 60,
        code: 200,
        ets: 70
      ]

      samples = report(nil, reading(memory: memory), nil)

      for {kind, bytes} <- memory do
        assert samples["beam_vm_mem_#{kind}_bytes"] == bytes
      end
    end

    test "a VM that cannot add its memory up reports the rest" do
      samples = report(nil, reading(atoms: {10, 1000}), nil)
      refute Enum.any?(Map.keys(samples), &(is_binary(&1) and &1 =~ "beam_vm_mem_"))
      assert samples["beam_vm_atoms"] == 10
    end

    test "what has a limit is reported with its share of the limit" do
      samples =
        report(
          nil,
          reading(
            processes: {250, 1_000},
            ports: {1, 8},
            atoms: {500, 1_000},
            ets_tables: {0, 50},
            persistent_terms: 3,
            persistent_term_bytes: 4_096,
            uptime_ms: 61_500
          ),
          nil
        )

      assert samples["beam_vm_processes"] == 250
      assert samples["beam_vm_processes_pct"] == 25.0
      assert samples["beam_vm_ports"] == 1
      assert samples["beam_vm_ports_pct"] == 12.5
      assert samples["beam_vm_atoms"] == 500
      assert samples["beam_vm_atoms_pct"] == 50.0
      assert samples["beam_vm_ets_tables"] == 0
      assert samples["beam_vm_ets_tables_pct"] == 0.0
      assert samples["beam_vm_persistent_terms"] == 3
      assert samples["beam_vm_persistent_term_bytes"] == 4_096
      assert samples["beam_vm_uptime_seconds"] == 61.5
    end

    test "microstates are shares of the time of all threads, and add up to 100" do
      before = %{emulator: 1_000, gc: 100, sleep: 50_000, other: 0, nif: 7}
      now = %{emulator: 1_600, gc: 200, sleep: 50_300, other: 0, nif: 7}

      samples = report(reading(msacc: before), reading(msacc: now), 1.0)

      assert samples["beam_vm_msacc_emulator_pct"] == 60.0
      assert samples["beam_vm_msacc_gc_pct"] == 10.0
      assert samples["beam_vm_msacc_sleep_pct"] == 30.0
      assert samples["beam_vm_msacc_other_pct"] == 0.0
      # A state that only some builds have.
      assert samples["beam_vm_msacc_nif_pct"] == 0.0
    end

    test "microstate counters that were reset leave a gap" do
      samples =
        report(
          reading(msacc: %{emulator: 1_000, sleep: 50_000}),
          reading(msacc: %{emulator: 10, sleep: 50_500}),
          1.0
        )

      refute Enum.any?(Map.keys(samples), &(is_binary(&1) and &1 =~ "msacc"))
    end

    test "microstates are not reported while accounting is off" do
      for {before, now} <- [{nil, %{sleep: 5}}, {%{sleep: 1}, nil}, {%{sleep: 5}, %{sleep: 5}}] do
        samples = report(reading(msacc: before), reading(msacc: now), 1.0)
        refute Enum.any?(Map.keys(samples), &(is_binary(&1) and &1 =~ "msacc"))
      end
    end
  end

  describe "the VM's own layout" do
    test "scheduler times are of the normal schedulers, then dirty CPU, then dirty I/O" do
      :erlang.system_flag(:scheduler_wall_time, true)
      ids = :erlang.statistics(:scheduler_wall_time_all) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      normal = :erlang.system_info(:schedulers)
      dirty_cpu = :erlang.system_info(:dirty_cpu_schedulers)
      dirty_io = :erlang.system_info(:dirty_io_schedulers)

      assert ids == Enum.to_list(1..(normal + dirty_cpu + dirty_io))

      # Without `_all` the dirty I/O schedulers are left out, and they are
      # the last.
      fewer = :erlang.statistics(:scheduler_wall_time) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert fewer == Enum.to_list(1..(normal + dirty_cpu))
    end

    test "there is a run queue for each normal scheduler, and one for each kind of dirty one" do
      queues = :erlang.statistics(:run_queue_lengths_all)
      assert length(queues) == :erlang.system_info(:schedulers) + 2
      assert length(:erlang.statistics(:run_queue_lengths)) + 1 == length(queues)
    end

    test "work for a dirty CPU scheduler is time of a dirty CPU scheduler" do
      :erlang.system_flag(:scheduler_wall_time, true)
      normal = :erlang.system_info(:schedulers)
      dirty_cpu = :erlang.system_info(:dirty_cpu_schedulers)

      active = fn ->
        for {id, active, _} <- :erlang.statistics(:scheduler_wall_time_all),
            id > normal and id <= normal + dirty_cpu,
            reduce: 0,
            do: (sum -> sum + active)
      end

      before = active.()
      # A collection that is asked for of a large heap is done by a dirty
      # CPU scheduler.
      heap = Enum.to_list(1..2_000_000)
      :erlang.garbage_collect()
      assert length(heap) == 2_000_000
      assert active.() > before
    end
  end

  describe "on the live VM" do
    setup do
      was_on = :erlang.system_flag(:microstate_accounting, false)
      on_exit(fn -> :erlang.system_flag(:microstate_accounting, was_on) end)
      :ok
    end

    test "the first reading has every level, and they make sense" do
      state = Vm.new(Options.new!([]))
      {state, batch} = Vm.collect(state, Batch.new(0), mono())
      samples = by_series(batch)

      for name <- ~w(beam_vm_run_queue beam_vm_run_queue_dirty_cpu beam_vm_run_queue_dirty_io
                     beam_vm_ets_tables beam_vm_persistent_terms beam_vm_persistent_term_bytes
                     beam_vm_uptime_seconds) do
        assert samples[name] >= 0, name
      end

      for kind <- ~w(total processes processes_used system atom atom_used binary code ets) do
        assert samples["beam_vm_mem_#{kind}_bytes"] > 0, kind
      end

      assert samples["beam_vm_mem_total_bytes"] >=
               samples["beam_vm_mem_processes_bytes"] + samples["beam_vm_mem_binary_bytes"]

      for name <- ~w(beam_vm_processes beam_vm_ports beam_vm_atoms beam_vm_ets_tables) do
        assert is_integer(samples[name])
        assert samples[name <> "_pct"] >= 0.0
        assert samples[name <> "_pct"] <= 100.0
      end

      # This process, at the least.
      assert samples["beam_vm_processes"] >= 1
      assert samples["beam_vm_atoms"] > 1_000

      for name <- @rates, do: refute(is_map_key(samples, name))
      refute scheduler(samples, :all)

      assert Vm.close(state) == :ok
    end

    test "the second reading has the rates of what was done between the two" do
      state = Vm.new(Options.new!([]))
      start = mono()
      {state, _batch} = Vm.collect(state, Batch.new(0), start)

      spin(100)
      for _ <- 1..20, do: make_garbage()
      through_a_port = through_a_port(64 * 1024)

      finish = mono()
      {state, batch} = Vm.collect(state, Batch.new(0), finish)
      samples = by_series(batch)
      seconds = finish - start

      assert samples["beam_vm_reductions_per_sec"] > 0
      assert samples["beam_vm_gcs_per_sec"] * seconds >= 19
      assert samples["beam_vm_gc_reclaimed_bytes_per_sec"] > 0
      assert samples["beam_vm_context_switches_per_sec"] >= 0
      assert samples["beam_vm_cpu_pct"] > 0

      # Rounded to a whole number of bytes a second, so within one a second.
      assert samples["beam_vm_io_in_bytes_per_sec"] * seconds >= through_a_port - seconds
      assert samples["beam_vm_io_out_bytes_per_sec"] * seconds >= through_a_port - seconds

      assert Vm.close(state) == :ok
    end

    test "every scheduler online is reported, and none is busy more than all the time" do
      state = Vm.new(Options.new!([]))
      {state, _batch} = Vm.collect(state, Batch.new(0), mono())
      spin(50)
      {state, batch} = Vm.collect(state, Batch.new(0), mono())
      samples = by_series(batch)

      online = :erlang.system_info(:schedulers_online)

      for id <- [:all | Enum.to_list(1..online)] do
        assert scheduler(samples, id) >= 0.0, "scheduler #{id}"
        assert scheduler(samples, id) <= 100.0, "scheduler #{id}"
      end

      refute scheduler(samples, online + 1)
      # This process ran, on one of them.
      assert scheduler(samples, :all) > 0.0

      for name <- ~w(beam_vm_dirty_cpu_util_pct beam_vm_dirty_io_util_pct) do
        assert samples[name] >= 0.0
        assert samples[name] <= 100.0
      end

      Vm.close(state)
    end

    test "with each scheduler not asked for, only all of them together are reported" do
      state = Vm.new(Options.new!(per_scheduler: false))
      {state, _batch} = Vm.collect(state, Batch.new(0), mono())
      spin(20)
      {state, batch} = Vm.collect(state, Batch.new(0), mono())

      utils =
        for {"beam_vm_scheduler_util_pct", labels, _} <- Batch.samples(batch), do: labels

      assert utils == [[{"scheduler", "all"}]]
      Vm.close(state)
    end

    test "scheduler times are kept from new until close" do
      kept_for_another? = kept_for_another?()

      state = Vm.new(Options.new!([]))
      assert scheduler_times_kept?()

      Vm.close(state)
      assert kept_for_another? or eventually(fn -> not scheduler_times_kept?() end)
    end

    test "scheduler times asked for by a process are no longer kept when it ends" do
      kept_for_another? = kept_for_another?()

      {pid, ref} =
        spawn_monitor(fn ->
          Vm.new(Options.new!([]))
          assert scheduler_times_kept?()
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      # Which is why `new/1` is called by the process that collects.
      assert kept_for_another? or eventually(fn -> not scheduler_times_kept?() end)
    end

    test "microstate accounting is left off unless asked for" do
      state = Vm.new(Options.new!([]))
      {state, _batch} = Vm.collect(state, Batch.new(0), mono())
      {state, batch} = Vm.collect(state, Batch.new(0), mono() + 1)

      refute Enum.any?(Batch.samples(batch), fn {name, _, _} -> name =~ "msacc" end)
      Vm.close(state)
      assert :erlang.system_flag(:microstate_accounting, false) == false
    end

    test "microstate accounting that was off is turned on, and off again at the end" do
      state = Vm.new(Options.new!(msacc: true))
      assert :erlang.system_flag(:microstate_accounting, true) == true

      Vm.close(state)
      assert :erlang.system_flag(:microstate_accounting, false) == false
    end

    test "microstate accounting that was on already is left on" do
      :erlang.system_flag(:microstate_accounting, true)

      state = Vm.new(Options.new!(msacc: true))
      Vm.close(state)

      assert :erlang.system_flag(:microstate_accounting, false) == true
    end

    test "the microstates of the live VM add up to all of its threads' time" do
      state = Vm.new(Options.new!(msacc: true))
      {state, batch} = Vm.collect(state, Batch.new(0), mono())
      refute Enum.any?(Batch.samples(batch), fn {name, _, _} -> name =~ "msacc" end)

      spin(50)
      {state, batch} = Vm.collect(state, Batch.new(0), mono())

      shares =
        for {"beam_vm_msacc_" <> state_pct, [], share} <- Batch.samples(batch),
            into: %{},
            do: {String.replace_suffix(state_pct, "_pct", ""), share}

      for state <- ~w(emulator gc port check_io aux sleep other) do
        assert shares[state] >= 0.0, state
        assert shares[state] <= 100.0, state
      end

      assert shares["emulator"] > 0.0
      # Each is rounded to a thousandth.
      assert_in_delta shares |> Map.values() |> Enum.sum(), 100.0, 0.001 * map_size(shares)

      Vm.close(state)
    end
  end

  defp scheduler_times_kept?, do: is_list(:erlang.statistics(:scheduler_wall_time_all))

  # Whether something else in this VM has asked for scheduler times, so
  # that they are kept whatever a test does. The VM lets go of a process's
  # hold on them a moment after the process has ended, and the test before
  # this one was such a process.
  defp kept_for_another?, do: not eventually(fn -> not scheduler_times_kept?() end)

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(5) && eventually(fun, tries - 1)
    end
  end

  # Work, for this many milliseconds.
  defp spin(ms), do: spin_until(System.monotonic_time(:millisecond) + ms, 0)

  defp spin_until(deadline, n) do
    if System.monotonic_time(:millisecond) < deadline, do: spin_until(deadline, n + 1), else: n
  end

  defp make_garbage do
    list = Enum.map(1..5_000, &{&1, &1})
    assert length(list) == 5_000
    :erlang.garbage_collect()
  end

  # Send this many bytes to a program that sends them back. Returns how
  # many went each way.
  defp through_a_port(bytes) do
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])
    Port.command(port, :binary.copy(<<"x">>, bytes))
    assert receive_bytes(port, bytes) == bytes
    Port.close(port)
    bytes
  end

  defp receive_bytes(_port, 0), do: 0

  defp receive_bytes(port, waiting) do
    receive do
      {^port, {:data, data}} -> byte_size(data) + receive_bytes(port, waiting - byte_size(data))
    after
      5_000 -> flunk("the port did not send back what it was sent")
    end
  end
end
