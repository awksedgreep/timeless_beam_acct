defmodule TimelessBeamAcct.RemoteTest do
  @moduledoc """
  Against a node that the test starts, which has Elixir in it and nothing
  of a collector.
  """

  # Not async: a node's name is the whole VM's.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias TimelessBeamAcct.{Cluster, Remote, Tick}

  @moduletag :distributed
  @moduletag :capture_log

  unless Cluster.possible?() do
    @moduletag skip: "the node cannot be distributed: there is no epmd"
  end

  setup_all do
    case Cluster.distribute() do
      {:ok, cookie, undo} ->
        on_exit(undo)
        {:ok, cookie: cookie}

      {:error, why} ->
        IO.puts(:stderr, "\nnot tested against other nodes: #{why}")
        {:ok, cookie: nil}
    end
  end

  # A node with Elixir in it, as an application built with Elixir is.
  defp elixir_node(cookie) do
    paths =
      for app <- [:elixir, :logger],
          do: [~c"-pa", Path.join(:code.lib_dir(app), "ebin") |> String.to_charlist()]

    peer =
      Cluster.start_peer(cookie,
        args: [~c"-setcookie", Atom.to_charlist(cookie) | Enum.concat(paths)]
      )

    {:ok, _} = :erpc.call(peer, :application, :ensure_all_started, [:elixir])
    {:ok, _} = :erpc.call(peer, :application, :ensure_all_started, [:logger])
    # What it logs, it logs to the terminal of the tests.
    :ok = :erpc.call(peer, Logger, :configure, [[level: :emergency]])
    peer
  end

  defp to_me do
    name = :"remote_test_#{System.unique_integer([:positive])}"
    Process.register(self(), name)
    {:forward, to: {name, node()}}
  end

  test "a collector is put into a node that was built without one, and taken out again",
       context do
    if context.cookie do
      peer = elixir_node(context.cookie)
      assert :erpc.call(peer, :code, :is_loaded, [TimelessBeamAcct]) == false
      refute Remote.attached?(peer)

      assert {:ok, collector} =
               Remote.attach(peer,
                 sink: to_me(),
                 interval: 3600,
                 process_interval: 3600,
                 min_age: 0
               )

      assert node(collector) == peer
      assert Remote.attached?(peer)
      assert :erpc.call(peer, TimelessBeamAcct, :running?, []) == true

      # It accounts for the node it is in.
      :ok = :erpc.call(peer, TimelessBeamAcct, :tick, [])
      :ok = :erpc.call(peer, TimelessBeamAcct, :tick, [])
      host = TimelessBeamAcct.Options.hostname()
      there = Atom.to_string(peer)

      assert_receive {:timeless_beam_acct, :tick, ^host, ^there, %Tick{metrics: %{count: count}}}
                     when count > 0,
                     5_000

      assert {:ok, %{sweep: %{processes: processes}, options: options}} = Remote.status(peer)
      assert processes > 10
      assert options.node == there

      assert :ok = Remote.detach(peer)
      refute Remote.attached?(peer)
      assert :erpc.call(peer, :code, :is_loaded, [TimelessBeamAcct]) == false
      assert :erpc.call(peer, :code, :is_loaded, [TimelessBeamAcct.Collector]) == false
      assert :erpc.call(peer, Process, :whereis, [TimelessBeamAcct.Collector]) == nil
    end
  end

  test "the collector stays when the process that attached it is gone", context do
    if context.cookie do
      peer = elixir_node(context.cookie)
      test = self()
      sink = to_me()

      {pid, ref} =
        spawn_monitor(fn ->
          send(test, Remote.attach(peer, sink: sink, interval: 3600, process_interval: 3600))
        end)

      assert_receive {:ok, _collector}, 10_000
      assert_receive {:DOWN, ^ref, _, ^pid, _}
      Process.sleep(50)

      assert Remote.attached?(peer)
      assert :ok = Remote.detach(peer)
    end
  end

  test "a node is looked at from another", context do
    if context.cookie do
      peer = elixir_node(context.cookie)

      {:ok, _} =
        Remote.attach(peer, sink: to_me(), interval: 3600, process_interval: 3600, min_age: 0)

      failed = :erpc.call(peer, :erlang, :spawn, [:erlang, :exit, [:on_purpose]])
      :ok = :erpc.call(peer, TimelessBeamAcct, :tick, [])
      Process.sleep(100)
      :ok = :erpc.call(peer, TimelessBeamAcct, :tick, [])

      top = capture_io(fn -> assert Remote.top(peer, n: 5) == :ok end)
      assert top =~ "#{peer}"
      assert top =~ "PID  APP"

      exits = capture_io(fn -> assert Remote.exits(peer, status: "on_purpose") == :ok end)
      assert exits =~ "on_purpose"
      assert exits =~ "erpc.execute_call/4" or exits =~ "erlang.exit/1"

      assert exits =~
               failed
               |> :erlang.pid_to_list()
               |> List.to_string()
               |> String.replace(~r/^<\d+/, "<0")

      summary = capture_io(fn -> assert Remote.exits(peer, summary: true, by: :app) == :ok end)
      assert summary =~ "COUNT  FAILED"

      trees = capture_io(fn -> assert Remote.trees(peer, failed: true) == :ok end)
      assert trees =~ "[exited on_purpose]"

      check = capture_io(fn -> assert Remote.check(peer) == :ok end)
      assert check =~ ~r/^collector +running: a sweep of/m
      assert check =~ ~r/^word of each exit +heard/m

      assert :ok = Remote.detach(peer)
    end
  end

  test "a node is reached from a terminal", context do
    if context.cookie do
      peer = elixir_node(context.cookie)
      was = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(was) end)
      reach = [Atom.to_string(peer), "--cookie", Atom.to_string(context.cookie)]

      attached =
        capture_io(fn ->
          Mix.Tasks.TimelessBeamAcct.Attach.run(
            reach ++
              ~w(--sink http --metrics-url http://127.0.0.1:1 --logs-url http://127.0.0.1:1) ++
              ~w(--traces-url http://127.0.0.1:1 --process-interval 1h --interval 1h) ++
              ~w(--min-age 0 --no-traces --max-processes 50 --records abnormal --timeout 0.2)
          )
        end)

      assert_received {:mix_shell, :info, ["A collector is running in " <> _]}
      assert attached =~ ~r/^metrics plane +http:\/\/127.0.0.1:1  connection refused$/m

      assert {:ok, %{options: options}} = Remote.status(peer)
      assert options.process_interval == 3600.0
      assert options.min_age == 0.0
      assert options.max_processes == 50
      assert options.records == :abnormal
      refute options.traces
      assert {TimelessBeamAcct.Sink.Http, sink} = options.sink
      assert sink[:metrics_url] == "http://127.0.0.1:1"
      assert sink[:timeout] == "0.2"

      :ok = :erpc.call(peer, TimelessBeamAcct, :tick, [])

      top =
        capture_io(fn -> Mix.Tasks.TimelessBeamAcct.Top.run(reach ++ ~w(--sort memory -n 3)) end)

      assert top =~ "PID  APP"
      assert top |> String.split("\n", trim: true) |> length() == 6

      exits =
        capture_io(fn ->
          Mix.Tasks.TimelessBeamAcct.Exits.run(reach ++ ~w(--since -1m --summary --by app))
        end)

      assert exits =~ "COUNT" or exits =~ "(none)"

      trees = capture_io(fn -> Mix.Tasks.TimelessBeamAcct.Trees.run(reach ++ ~w(--failed)) end)
      assert trees =~ "(none)"

      check = capture_io(fn -> Mix.Tasks.TimelessBeamAcct.Check.run(reach) end)
      assert check =~ ~r/^collector +running/m

      Mix.Tasks.TimelessBeamAcct.Detach.run(reach)
      assert_received {:mix_shell, :info, ["The collector in " <> _]}
      refute Remote.attached?(peer)
    end
  end

  test "what a terminal cannot make sense of is said, and nothing is done" do
    assert_raise Mix.Error, ~r/Which node\?/, fn -> Mix.Tasks.TimelessBeamAcct.Top.run([]) end

    assert_raise Mix.Error, ~r/--sorted is not understood/, fn ->
      Mix.Tasks.TimelessBeamAcct.Top.run(~w(app@ohm --sorted memory))
    end

    assert_raise Mix.Error, ~r/is not the name of a node/, fn ->
      Mix.Tasks.TimelessBeamAcct.Check.run(~w(nowhere))
    end
  end

  test "a node with no collector in it says so", context do
    if context.cookie do
      peer = elixir_node(context.cookie)
      assert capture_io(fn -> Remote.check(peer) end) =~ "can have a collector put into it"
      assert {:error, no} = Remote.detach(peer)
      assert no =~ "could not"
    end
  end

  test "what is wrong is refused, and nothing is left in the node", context do
    if context.cookie do
      peer = elixir_node(context.cookie)

      assert {:error, "unknown option :intervl"} = Remote.attach(peer, intervl: 5)
      assert :erpc.call(peer, :code, :is_loaded, [TimelessBeamAcct]) == false

      assert {:error, reason} = Remote.attach(peer, sink: :forward)
      assert reason =~ "could not be started"
      assert :erpc.call(peer, :code, :is_loaded, [TimelessBeamAcct]) == false
      refute Remote.attached?(peer)

      sink = to_me()
      {:ok, _} = Remote.attach(peer, sink: sink, interval: 3600, process_interval: 3600)
      assert {:error, twice} = Remote.attach(peer, sink: sink)
      assert twice =~ "already"
      # The one that is there is left as it is.
      assert Remote.attached?(peer)
      assert :ok = Remote.detach(peer)
    end
  end

  test "a node with no Elixir in it is refused", context do
    if context.cookie do
      peer = Cluster.start_peer(context.cookie)
      assert {:error, reason} = Remote.attach(peer, sink: :stdout)
      assert reason =~ "has no Elixir in it"
    end
  end

  test "this node is not attached to: a collector is started in it" do
    if Node.alive?() do
      assert {:error, reason} = Remote.attach(node(), sink: :stdout)
      assert reason =~ "is this node"
    end
  end

  test "a node that is not there cannot be reached" do
    if Node.alive?() do
      assert {:error, reason} =
               Remote.connect("nobody_#{System.unique_integer([:positive])}@localhost")

      assert reason =~ "cannot be reached"
    end

    assert {:error, reason} = Remote.connect("not a node")
    assert reason =~ "is not the name of a node"
  end

  test "what is sent is the collector, and not the tasks that are run from a terminal" do
    modules = Remote.modules()
    assert TimelessBeamAcct in modules
    assert TimelessBeamAcct.Collector in modules
    assert TimelessBeamAcct.Sink.Http in modules
    refute Enum.any?(modules, &String.starts_with?(Atom.to_string(&1), "Elixir.Mix."))
  end
end
