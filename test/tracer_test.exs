defmodule TimelessBeamAcct.TracerTest do
  use ExUnit.Case, async: true

  # Of OTP 27, and called only where it is found.
  @compile {:no_warn_undefined, [{:proc_lib, :set_label, 1}, :trace]}

  alias TimelessBeamAcct.{Ending, Identity, Options, Tracer}

  @moduletag skip: if(Tracer.available?(), do: false, else: "this VM has no trace sessions")

  defmodule Server do
    use GenServer
    def init(arg), do: {:ok, arg}
  end

  defp start(given \\ []) do
    name = :"tracer_test_#{System.unique_integer([:positive])}"
    options = Options.new!([name: name, sink: :stdout, anomalies: false] ++ given)
    start_supervised!({Tracer, options}, id: name)
    {options, Tracer.handle(options)}
  end

  # What is heard of these processes, once the last of them has been heard
  # to end, or to do whatever is `last`.
  defp heard(handle, pids, last \\ :exit, acc \\ [], tries \\ 400) do
    acc = acc ++ Tracer.take(handle)
    ended = for {_, ^last, _, pid, _} <- acc, do: pid

    cond do
      Enum.all?(pids, &(&1 in ended)) -> Enum.filter(acc, fn {_, _, _, pid, _} -> pid in pids end)
      tries == 0 -> flunk("never heard the end of #{inspect(pids -- ended)}")
      true -> Process.sleep(5) && heard(handle, pids, last, acc, tries - 1)
    end
  end

  test "a process is heard of when it starts and when it ends, with what it was and why" do
    {_options, handle} = start()
    me = self()

    pid = spawn(Kernel, :exit, [:custom])

    assert [{_, :born, born, ^pid, {^me, identity}}, {_, :exit, ended, ^pid, ending}] =
             heard(handle, [pid])

    assert identity.call == {Kernel, :exit, 1}
    assert %Ending{status: "custom", class: :abnormal} = ending
    assert ended >= born
  end

  test "a name is heard of when it is taken and when it is given up" do
    {_options, handle} = start()
    name = :"tracer_named_#{System.unique_integer([:positive])}"

    {:ok, pid} = GenServer.start(Server, :arg, name: name)
    GenServer.stop(pid)

    assert [
             {_, :born, _, ^pid, {_, %Identity{call: {Server, :init, 1}, name: ^name}}},
             {_, :name, _, ^pid, ^name},
             {_, :exit, _, ^pid, %Ending{status: "normal"}},
             {_, :unname, _, ^pid, ^name}
           ] = heard(handle, [pid], :unname)
  end

  test "what is taken is no longer there, and is in the order it happened" do
    {_options, handle} = start()
    pids = for _ <- 1..50, do: spawn(fn -> :ok end)

    # Each taking is in order. Two takings are not, one after the other:
    # what was heard late is taken late, with the time it happened.
    takings = takings(handle, pids)
    events = Enum.concat(takings)

    for taking <- takings do
      times = for {_, _, at, _, _} <- taking, do: at
      assert times == Enum.sort(times)
    end

    assert events |> Enum.filter(fn {_, _, _, pid, _} -> pid in pids end) |> length() == 100
    assert Tracer.take(handle) |> Enum.filter(fn {_, _, _, pid, _} -> pid in pids end) == []
  end

  defp takings(handle, pids, acc \\ [], tries \\ 400) do
    acc = [Tracer.take(handle) | acc]
    ended = for taking <- acc, {_, :exit, _, pid, _} <- taking, do: pid

    cond do
      Enum.all?(pids, &(&1 in ended)) -> Enum.reverse(acc)
      tries == 0 -> flunk("never heard the end of #{inspect(pids -- ended)}")
      true -> Process.sleep(5) && takings(handle, pids, acc, tries - 1)
    end
  end

  test "a crash is heard of as what was raised" do
    {_options, handle} = start()

    ExUnit.CaptureLog.capture_log(fn ->
      pid = spawn(fn -> raise ArgumentError, "no" end)

      assert [_, {_, :exit, _, ^pid, ending}] = heard(handle, [pid])

      assert %Ending{status: "ArgumentError", class: :crashed, reason: "ArgumentError: no"} =
               ending

      assert ending.at =~ "tracer_test.exs"
    end)
  end

  describe "what a process says it is" do
    test "a task is heard of when it takes up what it was sent to do" do
      {_options, handle} = start()
      {:ok, supervisor} = Task.Supervisor.start_link()

      by_function = Task.Supervisor.async(supervisor, fn -> :done end)
      Task.await(by_function)
      by_name = Task.async(Enum, :count, [[1, 2]])
      Task.await(by_name)

      events = heard(handle, [by_function.pid, by_name.pid])
      of = fn task -> Enum.filter(events, fn {_, _, _, pid, _} -> pid == task.pid end) end

      assert [
               {_, :born, _, _, _},
               {_, :call, _, _, {__MODULE__, function, 0}},
               {_, :exit, _, _, _}
             ] =
               of.(by_function)

      assert Atom.to_string(function) =~ "a task is heard of"

      assert [{_, :born, _, _, _}, {_, :call, _, _, {Enum, :count, 1}}, {_, :exit, _, _, _}] =
               of.(by_name)
    end

    test "what a task was given to work on is not sent for" do
      {_options, handle} = start()
      large = Enum.to_list(1..100_000)
      task = Task.async(Enum, :count, [large])
      Task.await(task)

      events = heard(handle, [task.pid])
      assert :erts_debug.flat_size(events) < 1000
    end

    test "a label is heard of when a process gives itself one" do
      if function_exported?(:proc_lib, :set_label, 1) do
        {_options, handle} = start()
        pid = spawn(fn -> :proc_lib.set_label({:connection, 42}) end)

        assert [{_, :born, _, _, _}, {_, :label, _, ^pid, "connection"}, {_, :exit, _, _, _}] =
                 heard(handle, [pid])
      end
    end

    test "is not asked for, if it is not wanted" do
      {_options, handle} = start(descriptions: false)
      task = Task.async(Enum, :count, [[1, 2]])
      Task.await(task)

      assert [{_, :born, _, _, _}, {_, :exit, _, _, _}] = heard(handle, [task.pid])
    end
  end

  test "what is heard is counted" do
    {_options, handle} = start()
    before = Tracer.counts(handle)
    pids = for _ <- 1..10, do: spawn(fn -> :ok end)
    heard(handle, pids)
    counts = Tracer.counts(handle)

    assert counts.listening
    assert counts.spawns - before.spawns >= 10
    assert counts.exits - before.exits >= 10
    assert counts.suspensions == 0
  end

  test "another session hears what this one hears, and neither takes it from the other" do
    {_options, handle} = start()
    {_other_options, other} = start()

    pid = spawn(fn -> :ok end)
    assert [{_, :born, _, ^pid, _}, {_, :exit, _, ^pid, _}] = heard(handle, [pid])
    assert [{_, :born, _, ^pid, _}, {_, :exit, _, ^pid, _}] = heard(other, [pid])
  end

  test "with too much waiting it stops listening, says so, and listens again" do
    {options, handle} = start(trace_max_queue: 100, trace_resume_after: 0.05)
    tracer = Process.whereis(Options.name(options, :Tracer))

    # Held still while the queue fills, as a tracer that cannot keep up is.
    :erlang.suspend_process(tracer)
    for _ <- 1..2000, do: spawn(fn -> :ok end)
    :erlang.resume_process(tracer)

    wait_until(fn -> Tracer.counts(handle).suspensions > 0 end)
    wait_until(fn -> Tracer.counts(handle).listening end)

    gaps = for {_, :gap, _, _, which} <- drain(handle), do: which
    assert [:begin, :end | _] = gaps

    pid = spawn(fn -> :ok end)
    assert [{_, :born, _, ^pid, _}, {_, :exit, _, ^pid, _}] = heard(handle, [pid])
  end

  test "when the tracer ends, the VM stops sending" do
    {options, _handle} = start()
    session = Options.name(options, :Session)
    assert Enum.any?(:trace.session_info(:all), &match?({^session, _}, &1))

    stop_supervised!(options.name)
    refute Enum.any?(:trace.session_info(:all), &match?({^session, _}, &1))
  end

  test "when the tracer is killed, the VM stops sending" do
    Process.flag(:trap_exit, true)
    name = :"tracer_test_#{System.unique_integer([:positive])}"
    options = Options.new!(name: name, sink: :stdout, anomalies: false)
    {:ok, tracer} = Tracer.start_link(options)
    session = Options.name(options, :Session)
    assert Enum.any?(:trace.session_info(:all), &match?({^session, _}, &1))

    # With no chance to end what it began.
    Process.exit(tracer, :kill)
    assert_receive {:EXIT, ^tracer, :killed}

    wait_until(fn ->
      not Enum.any?(:trace.session_info(:all), &match?({^session, _}, &1))
    end)
  end

  test "without word of exits there is no tracer" do
    options = Options.new!(name: :tracer_test_none, sink: :stdout, exits: false)
    assert Tracer.start_link(options) == :ignore
    assert Tracer.handle(options) == nil
  end

  describe "remarks" do
    @describetag skip:
                   if(Tracer.remarks?(),
                     do: false,
                     else: "a trace session of this VM has no system monitor"
                   )

    test "a heap that grows large is remarked on once, however often it is collected" do
      {_options, handle} = start(anomalies: true, large_heap: 1024 * 1024)

      pid =
        spawn(fn ->
          list = Enum.to_list(1..400_000)
          receive(do: (:stop -> length(list)))
        end)

      remarks = wait_for(handle, :remark, pid)
      assert [{_, :remark, _, ^pid, {:large_heap, bytes, nil}}] = remarks
      assert bytes >= 1024 * 1024
      send(pid, :stop)
      assert Tracer.counts(handle).remarks >= 1
    end

    test "a queue that grows long is remarked on, and again when it has been worked down" do
      {_options, handle} = start(anomalies: true, long_message_queue: {5, 50})

      pid =
        spawn(fn ->
          receive(do: (:go -> :ok))
          for _ <- 1..100, do: receive(do: (:fill -> :ok))
          receive(do: (:stop -> :ok))
        end)

      for _ <- 1..100, do: send(pid, :fill)

      assert [{_, :remark, _, ^pid, {:long_message_queue, waiting, "raised"}}] =
               wait_for(handle, :remark, pid)

      assert waiting >= 50

      send(pid, :go)

      assert [{_, :remark, _, ^pid, {:long_message_queue, _, "cleared"}}] =
               wait_for(handle, :remark, pid)

      send(pid, :stop)
    end
  end

  describe "where a trace session has no system monitor" do
    @describetag skip:
                   if(Tracer.available?() and not Tracer.remarks?(),
                     do: false,
                     else: "a trace session of this VM has a system monitor, or there is none"
                   )

    test "a tracer told to hear remarks starts, hears of processes, and remarks on nothing" do
      {_options, handle} = start(anomalies: true, large_heap: 1024 * 1024)

      pid =
        spawn(fn ->
          list = Enum.to_list(1..400_000)
          receive(do: (:stop -> length(list)))
        end)

      Process.sleep(100)
      send(pid, :stop)

      assert [{_, :born, _, ^pid, _}, {_, :exit, _, ^pid, _}] = heard(handle, [pid])
      assert %{remarks: 0, remarks_dropped: 0, listening: true} = Tracer.counts(handle)
    end
  end

  defp drain(handle, acc \\ [], quiet \\ 0) do
    case Tracer.take(handle) do
      [] when quiet >= 10 -> acc
      [] -> Process.sleep(5) && drain(handle, acc, quiet + 1)
      events -> drain(handle, acc ++ events, 0)
    end
  end

  defp wait_for(handle, kind, pid, tries \\ 400) do
    case for {_, ^kind, _, ^pid, _} = event <- Tracer.take(handle), do: event do
      [] when tries == 0 -> flunk("never heard #{kind} of #{inspect(pid)}")
      [] -> Process.sleep(5) && wait_for(handle, kind, pid, tries - 1)
      events -> events
    end
  end

  defp wait_until(fun, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("never happened")
      true -> Process.sleep(5) && wait_until(fun, tries - 1)
    end
  end
end
