defmodule TimelessBeamAcct.Collect.DistTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.{Batch, Options}
  alias TimelessBeamAcct.Collect.Dist

  defp report(previous, reading, seconds) do
    Batch.new(0) |> Dist.report(previous, reading, seconds) |> by_series()
  end

  defp by_series(%Batch{} = batch) do
    samples = Batch.samples(batch)
    series = Enum.map(samples, fn {name, labels, _} -> {name, labels} end)
    assert series == Enum.uniq(series), "a series was reported twice"

    Map.new(samples, fn
      {name, [], value} -> {name, value}
      {name, [{"peer", peer}], value} -> {{name, peer}, value}
    end)
  end

  defp counters(received, sent, waiting \\ 0),
    do: %{in_bytes: received, out_bytes: sent, queue_bytes: waiting}

  # Something to stand for a connection's controller. What it is does not
  # matter to a report; that it is the same one or another does.
  defp controller, do: spawn(fn -> :ok end)

  test "a node with no connections reports that it has none" do
    nothing = %{nodes: 0, connections: %{}}
    assert report(nil, nothing, nil) == %{"beam_dist_nodes" => 0}
    assert report(nothing, nothing, 10.0) == %{"beam_dist_nodes" => 0}
  end

  test "the first reading of a connection gives what is waiting, and no rates" do
    reading = %{nodes: 1, connections: %{{:b@host, controller()} => counters(5_000, 7_000, 12)}}

    assert report(nil, reading, nil) == %{
             "beam_dist_nodes" => 1,
             {"beam_dist_queue_bytes", "b@host"} => 12
           }
  end

  test "a rate is the bytes that passed, over the time between two readings" do
    b = {:b@host, controller()}
    c = {:c@host, controller()}
    before = %{nodes: 2, connections: %{b => counters(1_000, 2_000), c => counters(50, 50)}}
    now = %{nodes: 2, connections: %{b => counters(21_000, 2_500, 64), c => counters(50, 50)}}

    assert report(before, now, 10.0) == %{
             "beam_dist_nodes" => 2,
             {"beam_dist_in_bytes_per_sec", "b@host"} => 2_000.0,
             {"beam_dist_out_bytes_per_sec", "b@host"} => 50.0,
             {"beam_dist_queue_bytes", "b@host"} => 64,
             {"beam_dist_in_bytes_per_sec", "c@host"} => 0.0,
             {"beam_dist_out_bytes_per_sec", "c@host"} => 0.0,
             {"beam_dist_queue_bytes", "c@host"} => 0
           }
  end

  test "a connection made again is a new one, though its counters are the higher" do
    before = %{nodes: 1, connections: %{{:b@host, controller()} => counters(1_000, 1_000)}}
    now = %{nodes: 1, connections: %{{:b@host, controller()} => counters(9_000, 9_000, 3)}}

    assert report(before, now, 10.0) == %{
             "beam_dist_nodes" => 1,
             {"beam_dist_queue_bytes", "b@host"} => 3
           }

    # And is an old one by the reading after.
    later =
      put_in(
        now.connections,
        Map.new(now.connections, fn {k, _} -> {k, counters(9_500, 9_000)} end)
      )

    assert report(now, later, 10.0)[{"beam_dist_in_bytes_per_sec", "b@host"}] == 50.0
  end

  test "a counter that went backwards leaves a gap" do
    b = {:b@host, controller()}
    before = %{nodes: 1, connections: %{b => counters(8_000, 100)}}
    now = %{nodes: 1, connections: %{b => counters(10, 300)}}

    samples = report(before, now, 2.0)
    refute is_map_key(samples, {"beam_dist_in_bytes_per_sec", "b@host"})
    assert samples[{"beam_dist_out_bytes_per_sec", "b@host"}] == 100.0
  end

  test "a connection whose counters cannot be read is counted, and has no series" do
    # Over TLS: two nodes connected, and one of them by a port.
    b = {:b@host, controller()}
    before = %{nodes: 2, connections: %{b => counters(0, 0)}}
    now = %{nodes: 2, connections: %{b => counters(10, 10)}}

    samples = report(before, now, 1.0)
    assert samples["beam_dist_nodes"] == 2
    assert for({{_name, peer}, _} <- samples, uniq: true, do: peer) == ["b@host"]
  end

  test "with no time between two readings there are no rates" do
    b = {:b@host, controller()}
    before = %{nodes: 1, connections: %{b => counters(0, 0)}}
    now = %{nodes: 1, connections: %{b => counters(10, 10, 1)}}

    for seconds <- [0, 0.0, -1.0, nil] do
      assert report(before, now, seconds) == %{
               "beam_dist_nodes" => 1,
               {"beam_dist_queue_bytes", "b@host"} => 1
             }
    end
  end

  test "a peer that is gone is reported once more, as nothing" do
    here = controller()

    connected = %{nodes: 1, connections: %{{:a@ohm, here} => counters(1000, 2000, 50)}}
    gone = %{nodes: 0, connections: %{}}

    samples = report(connected, gone, 10.0)

    assert samples["beam_dist_nodes"] == 0
    assert samples[{"beam_dist_queue_bytes", "a@ohm"}] == 0
    assert samples[{"beam_dist_in_bytes_per_sec", "a@ohm"}] == 0
    assert samples[{"beam_dist_out_bytes_per_sec", "a@ohm"}] == 0

    # And not again after that.
    assert report(gone, gone, 10.0) == %{"beam_dist_nodes" => 0}
  end

  test "a peer that is connected again by another connection is not gone" do
    connected = %{nodes: 1, connections: %{{:a@ohm, controller()} => counters(1000, 2000, 50)}}
    again = %{nodes: 1, connections: %{{:a@ohm, controller()} => counters(10, 20, 5)}}

    samples = report(connected, again, 10.0)

    # What is waiting is of the connection there is, and there are no
    # rates of a connection that has one reading.
    assert samples[{"beam_dist_queue_bytes", "a@ohm"}] == 5
    refute is_map_key(samples, {"beam_dist_in_bytes_per_sec", "a@ohm"})
  end

  test "the nodes connected are counted, on a node that is not distributed too" do
    state = Dist.new(Options.new!([]))
    {state, batch} = Dist.collect(state, Batch.new(0), 1.0)
    {state, again} = Dist.collect(state, batch, 2.0)

    for batch <- [batch, again] do
      assert {"beam_dist_nodes", [], nodes} =
               List.keyfind(Batch.samples(batch), "beam_dist_nodes", 0)

      assert is_integer(nodes) and nodes >= 0
      unless Node.alive?(), do: assert(nodes == 0 and batch.count in [1, 2])
    end

    assert Dist.close(state) == :ok
  end
end

defmodule TimelessBeamAcct.Collect.DistConnectedTest do
  @moduledoc """
  Against nodes that the test starts, and stops.

  The node that runs the tests is made a distributed one for as long as
  these tests run, under a name and a cookie made up for the occasion, so
  that nothing else on the host is of its cluster.
  """

  # Not async: a node's name is the whole VM's.
  use ExUnit.Case, async: false

  import TimelessBeamAcct.Cluster, only: [start_peer: 1, start_peer: 2, stop_peer: 1]

  alias TimelessBeamAcct.{Batch, Cluster, Options}
  alias TimelessBeamAcct.Collect.Dist

  @moduletag :distributed

  # Whether there is an epmd to be had is known before the tests run, and
  # then they are skipped, and said to be.
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
        # A test with no cookie has no cluster, and tests nothing.
        {:ok, cookie: nil}
    end
  end

  test "each peer has what is waiting from the first reading, and rates from the second",
       context do
    if context.cookie do
      one = start_peer(context.cookie)
      two = start_peer(context.cookie)

      state = Dist.new(Options.new!([]))
      {state, batch} = Dist.collect(state, Batch.new(0), 100.0)
      samples = by_series(batch)

      assert samples["beam_dist_nodes"] == length(Node.list(:connected))
      assert samples["beam_dist_nodes"] >= 2

      for peer <- [one, two] do
        assert samples[{"beam_dist_queue_bytes", peer}] >= 0
        refute is_map_key(samples, {"beam_dist_in_bytes_per_sec", peer})
        refute is_map_key(samples, {"beam_dist_out_bytes_per_sec", peer})
      end

      # A third of a megabyte there, and back.
      bytes = 333_333
      payload = :binary.copy(<<7>>, bytes)
      assert :erpc.call(one, :erlang, :iolist_to_binary, [[payload]]) == payload

      {state, batch} = Dist.collect(state, Batch.new(0), 101.0)
      samples = by_series(batch)

      assert samples[{"beam_dist_in_bytes_per_sec", one}] >= bytes
      assert samples[{"beam_dist_out_bytes_per_sec", one}] >= bytes
      assert samples[{"beam_dist_queue_bytes", one}] >= 0

      # Nothing was said to the other, which is not to say nothing passed:
      # nodes tell each other that they are there.
      assert samples[{"beam_dist_in_bytes_per_sec", two}] >= 0
      assert samples[{"beam_dist_in_bytes_per_sec", two}] < bytes
      assert samples[{"beam_dist_out_bytes_per_sec", two}] < bytes

      assert Dist.close(state) == :ok
    end
  end

  test "a peer that is gone is reported once more, as nothing, and then no longer", context do
    if context.cookie do
      peer = start_peer(context.cookie)

      state = Dist.new(Options.new!([]))
      {state, batch} = Dist.collect(state, Batch.new(0), 100.0)
      before = by_series(batch)
      assert is_map_key(before, {"beam_dist_queue_bytes", peer})

      stop_peer(peer)

      {state, batch} = Dist.collect(state, Batch.new(0), 101.0)
      samples = by_series(batch)

      assert samples["beam_dist_nodes"] == before["beam_dist_nodes"] - 1
      assert samples[{"beam_dist_queue_bytes", peer}] == 0
      assert samples[{"beam_dist_in_bytes_per_sec", peer}] == 0
      assert samples[{"beam_dist_out_bytes_per_sec", peer}] == 0

      {_state, batch} = Dist.collect(state, Batch.new(0), 102.0)
      refute Enum.any?(Map.keys(by_series(batch)), &match?({_name, ^peer}, &1))
    end
  end

  test "a peer that was connected again is a new connection, and an old one by the next reading",
       context do
    if context.cookie do
      # Told what to do over its standard input, so that it lives through
      # the loss of its connection.
      peer = start_peer(context.cookie, connection: :standard_io)
      assert Node.connect(peer)

      payload = :binary.copy(<<7>>, 100_000)
      assert :erpc.call(peer, :erlang, :byte_size, [payload]) == 100_000

      state = Dist.new(Options.new!([]))
      {state, _batch} = Dist.collect(state, Batch.new(0), 100.0)
      [connection] = for {{^peer, _}, _} = connection <- Dist.read().connections, do: connection

      :net_kernel.monitor_nodes(true)
      assert Node.disconnect(peer)
      assert_receive {:nodedown, ^peer}, 5_000
      assert Node.connect(peer)
      assert_receive {:nodeup, ^peer}, 5_000
      :net_kernel.monitor_nodes(false)

      # More than the old connection carried, so that the counters alone
      # would not tell the two apart.
      payload = :binary.copy(<<7>>, 400_000)
      assert :erpc.call(peer, :erlang, :byte_size, [payload]) == 400_000

      [again] = for {{^peer, _}, _} = connection <- Dist.read().connections, do: connection
      {{_, controller}, counters} = connection
      {{_, controller_again}, counters_again} = again
      assert controller_again != controller
      assert counters_again.out_bytes > counters.out_bytes

      {state, batch} = Dist.collect(state, Batch.new(0), 101.0)
      samples = by_series(batch)
      assert samples[{"beam_dist_queue_bytes", peer}] >= 0
      refute is_map_key(samples, {"beam_dist_out_bytes_per_sec", peer})
      refute is_map_key(samples, {"beam_dist_in_bytes_per_sec", peer})

      {_state, batch} = Dist.collect(state, Batch.new(0), 102.0)
      samples = by_series(batch)
      assert samples[{"beam_dist_out_bytes_per_sec", peer}] >= 0
      assert samples[{"beam_dist_in_bytes_per_sec", peer}] >= 0
    end
  end

  test "the controller of a connection over TCP is a port, and its socket keeps the counters",
       context do
    if context.cookie do
      peer = start_peer(context.cookie)

      assert {^peer, port} = List.keyfind(:erlang.system_info(:dist_ctrl), peer, 0)
      assert is_port(port)

      assert %{connections: %{{^peer, ^port} => counters}} = Dist.read()
      assert counters.in_bytes > 0
      assert counters.out_bytes > 0
      assert counters.queue_bytes >= 0
    end
  end

  # ---- nodes ----

  # The samples by name, and those of a peer by name and node.
  defp by_series(%Batch{} = batch) do
    Map.new(Batch.samples(batch), fn
      {name, [], value} -> {name, value}
      {name, [{"peer", peer}], value} -> {{name, String.to_atom(peer)}, value}
    end)
  end
end
