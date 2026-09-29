defmodule TimelessBeamAcct.Sink.ForwardTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.{Batch, Tick}
  alias TimelessBeamAcct.Sink.Forward

  defp tick, do: %Tick{metrics: Batch.push(Batch.new(1), "m", 1)}

  test "a tick is handed over as it is, with the host and the node" do
    {:ok, sink} = Forward.init(to: self())
    tick = tick()

    assert {:ok, ^sink} = Forward.write(sink, "ohm", "app@ohm", tick)
    assert_received {:timeless_beam_acct, :tick, "ohm", "app@ohm", ^tick}
  end

  test "an empty tick is handed over too" do
    {:ok, sink} = Forward.init(to: self())
    empty = %Tick{metrics: Batch.new(1)}

    assert {:ok, _} = Forward.write(sink, "h", "n", empty)
    assert_received {:timeless_beam_acct, :tick, "h", "n", ^empty}
  end

  test "a flush and a close are said" do
    {:ok, sink} = Forward.init(to: self())

    assert {:ok, ^sink} = Forward.flush(sink)
    assert_received {:timeless_beam_acct, :flush}

    assert :ok = Forward.close(sink)
    assert_received {:timeless_beam_acct, :close}
  end

  test "a process may be given by the name it is registered under", context do
    Process.register(self(), context.test)
    {:ok, sink} = Forward.init(to: context.test)

    assert {:ok, _} = Forward.write(sink, "h", "n", tick())
    assert_received {:timeless_beam_acct, :tick, "h", "n", %Tick{}}

    {:ok, sink} = Forward.init(to: {context.test, node()})
    assert {:ok, _} = Forward.flush(sink)
    assert_received {:timeless_beam_acct, :flush}
  end

  test "a name nothing is registered under is an error, and is not raised", context do
    {:ok, sink} = Forward.init(to: context.test)

    assert {:error, :noproc, ^sink} = Forward.write(sink, "h", "n", tick())
    assert {:error, :noproc, ^sink} = Forward.flush(sink)
    assert :ok = Forward.close(sink)
  end

  test "a process registered later is found", context do
    {:ok, sink} = Forward.init(to: context.test)
    assert {:error, :noproc, sink} = Forward.write(sink, "h", "n", tick())

    Process.register(self(), context.test)
    assert {:ok, _} = Forward.write(sink, "h", "n", tick())
    assert_received {:timeless_beam_acct, :tick, "h", "n", %Tick{}}
  end

  test "a process that has ended is sent to, as any is" do
    {pid, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    {:ok, sink} = Forward.init(to: pid)
    assert {:ok, ^sink} = Forward.write(sink, "h", "n", tick())
  end

  test "it cannot be made without a process to hand ticks to" do
    assert {:error, why} = Forward.init([])
    assert why =~ ":to"

    assert {:error, _} = Forward.init(to: nil)
    assert {:error, _} = Forward.init(to: "a name")
    assert {:error, why} = Forward.init(to: self(), also: self())
    assert why =~ ":also"
  end

  test "it is described by the process", context do
    {:ok, sink} = Forward.init(to: context.test)
    assert Forward.describe(sink) == "forward: to #{inspect(context.test)}"

    {:ok, sink} = Forward.init(to: self())
    assert Forward.describe(sink) == "forward: to #{inspect(self())}"
  end
end
