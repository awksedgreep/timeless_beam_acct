defmodule TimelessBeamAcct.ApplicationTest do
  # Not with the others: the application is the whole VM's.
  use ExUnit.Case, async: false

  alias TimelessBeamAcct.Tick

  @moduletag :capture_log

  setup do
    on_exit(fn ->
      Application.stop(:timeless_beam_acct)

      for {key, _} <- Application.get_all_env(:timeless_beam_acct),
          do: Application.delete_env(:timeless_beam_acct, key)

      {:ok, _} = Application.ensure_all_started(:timeless_beam_acct)
    end)

    Application.stop(:timeless_beam_acct)
    :ok
  end

  test "nothing is collected because the package is there" do
    {:ok, _} = Application.ensure_all_started(:timeless_beam_acct)
    refute TimelessBeamAcct.running?()
    assert TimelessBeamAcct.status() == nil
  end

  test "a collector is started with the application, if the configuration asks for one" do
    Process.register(self(), :application_test)

    Application.put_all_env(
      timeless_beam_acct: [
        start: true,
        sink: {:forward, to: :application_test},
        interval: 3600,
        process_interval: "1h",
        exits: false
      ]
    )

    {:ok, _} = Application.ensure_all_started(:timeless_beam_acct)
    assert TimelessBeamAcct.running?()
    assert TimelessBeamAcct.status().options.process_interval == 3600.0

    :ok = TimelessBeamAcct.tick()

    assert_receive {:timeless_beam_acct, :tick, _, _, %Tick{metrics: %{count: count}}}
                   when count > 0

    Application.stop(:timeless_beam_acct)
    refute TimelessBeamAcct.running?()
    assert_receive {:timeless_beam_acct, :close}
  end

  test "a collector that was started with the application can be stopped, and stays stopped" do
    Process.register(self(), :application_test_stop)

    Application.put_all_env(
      timeless_beam_acct: [
        start: true,
        sink: {:forward, to: :application_test_stop},
        interval: 3600,
        process_interval: 3600
      ]
    )

    {:ok, _} = Application.ensure_all_started(:timeless_beam_acct)
    assert TimelessBeamAcct.running?()

    assert TimelessBeamAcct.stop() == :ok
    assert_receive {:timeless_beam_acct, :close}
    # It is not started again, as a child that ended would be.
    Process.sleep(100)
    refute TimelessBeamAcct.running?()
    assert Supervisor.which_children(TimelessBeamAcct.Application.Supervisor) == []
  end

  test "a collector among the children of a supervisor does not start where the configuration says not to" do
    Application.put_env(:timeless_beam_acct, :start, false)
    {:ok, _} = Application.ensure_all_started(:timeless_beam_acct)

    name = :application_test_child
    child = {TimelessBeamAcct, name: name, sink: {:forward, to: self()}, interval: 3600}

    # As in the tests of an application that has one among its children.
    {:ok, supervisor} = Supervisor.start_link([child], strategy: :one_for_one)

    assert Supervisor.which_children(supervisor) == [
             {name, :undefined, :supervisor, [TimelessBeamAcct]}
           ]

    refute TimelessBeamAcct.running?(name)
    Supervisor.stop(supervisor)

    # Where the configuration says nothing, it starts.
    Application.delete_env(:timeless_beam_acct, :start)
    {:ok, supervisor} = Supervisor.start_link([child], strategy: :one_for_one)
    assert TimelessBeamAcct.running?(name)
    Supervisor.stop(supervisor)
  end

  test "an option that is wrong is refused, whether or not a collector is to start" do
    Application.put_env(:timeless_beam_acct, :start, false)

    assert_raise ArgumentError, ~r/unknown option/, fn ->
      TimelessBeamAcct.start_link(intervl: 5)
    end
  end
end
