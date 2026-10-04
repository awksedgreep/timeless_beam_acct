defmodule TimelessBeamAcct.RecordingTest do
  # Not with the others: a collector hears of every process of the node.
  use ExUnit.Case, async: false

  alias TimelessBeamAcct.{Event, Options, Recording, Tick}

  @moduletag :capture_log

  defp name, do: :"recording_test_#{System.unique_integer([:positive])}"

  defp options(name, more) do
    [
      name: name,
      sink: {:forward, to: self()},
      interval: 3600,
      process_interval: 3600,
      anomalies: false
    ] ++ more
  end

  # The records of the recording that were written, in order.
  defp recorded(timeout) do
    receive do
      {:timeless_beam_acct, :tick, _, _, %Tick{events: events}} ->
        mine = for %Event{fields: %{"kind" => "recording"}} = event <- events, do: event
        mine ++ recorded(timeout)
    after
      timeout -> []
    end
  end

  test "a recording ends by itself, and says so" do
    name = name()
    {:ok, sup} = TimelessBeamAcct.start_link(options(name, stop_after: 1, recorded_by: "mark"))
    Process.unlink(sup)
    ref = Process.monitor(sup)

    assert %{stop_at: stop_at, started: started, by: "mark", recording: id} =
             TimelessBeamAcct.status(name).recording

    assert_in_delta stop_at - started, 1.0, 0.01

    assert_receive {:DOWN, ^ref, :process, ^sup, :shutdown}, 5_000
    refute TimelessBeamAcct.running?(name)

    assert [started_record, ended_record] = recorded(500)
    assert %{"status" => "started", "recording" => ^id, "by" => "mark"} = started_record.fields
    assert started_record.fields["stop_after"] == 1.0
    assert %{"status" => "ended", "reason" => "time", "recording" => ^id} = ended_record.fields
    assert ended_record.message =~ "its time ran out"
    # Its records are not the records of processes that ended.
    assert TimelessBeamAcct.records(name: name) == []
  end

  test "a recording that is stopped says it was" do
    name = name()
    {:ok, sup} = TimelessBeamAcct.start_link(options(name, stop_after: "1h"))
    Process.unlink(sup)
    :ok = TimelessBeamAcct.stop(name)

    assert [%{fields: %{"status" => "started"}}, %{fields: %{"status" => "ended"} = ended}] =
             recorded(500)

    assert ended["reason"] == "stopped"
  end

  test "a recording is made to run longer, and no longer than it may" do
    name = name()
    {:ok, sup} = TimelessBeamAcct.start_link(options(name, stop_after: "1h", max_recording: "2h"))
    Process.unlink(sup)
    %{stop_at: first, started: started} = Recording.status(name)

    assert {:ok, later} = TimelessBeamAcct.extend(name, "30m")
    assert_in_delta later - first, 1800.0, 0.01
    assert Recording.status(name).stop_at == later

    assert {:error, why} = TimelessBeamAcct.extend(name, "1h")
    assert why =~ "may run 2h00m at most"
    assert {:ok, at_most} = TimelessBeamAcct.extend(name, "30m")
    assert_in_delta at_most - started, 7200.0, 0.01

    assert {:error, _} = TimelessBeamAcct.extend(name, "soon")
    assert {:error, _} = TimelessBeamAcct.extend(name, 0)
    :ok = TimelessBeamAcct.stop(name)
    assert {:error, why} = TimelessBeamAcct.extend(name, "1m")
    assert why =~ "is recording"
  end

  test "a collector that is not told how long is not a recording" do
    name = name()
    start_supervised!({TimelessBeamAcct, options(name, [])})
    assert TimelessBeamAcct.status(name).recording == nil
    assert Recording.status(name) == nil
  end

  test "a recording among the children of a supervisor is not started again when it ends" do
    name = name()

    {:ok, sup} =
      Supervisor.start_link([{TimelessBeamAcct, options(name, stop_after: 1)}],
        strategy: :one_for_one
      )

    assert TimelessBeamAcct.running?(name)
    Process.sleep(1_800)
    refute TimelessBeamAcct.running?(name)
    assert Process.alive?(sup)
    assert [{^name, :undefined, :supervisor, _}] = Supervisor.which_children(sup)
    Supervisor.stop(sup)
  end

  test "a recording that is to begin later waits, reading nothing, and then begins" do
    name = name()
    at = TimelessBeamAcct.Clock.now() + 1.2
    {:ok, sup} = TimelessBeamAcct.start_link(options(name, start_at: at, stop_after: 1))
    Process.unlink(sup)
    ref = Process.monitor(sup)

    assert %{waiting: %{start_at: ^at, stop_after: 1.0}} = TimelessBeamAcct.status(name)
    refute TimelessBeamAcct.running?(name)
    assert recorded(300) == []

    # It begins, runs its second, and ends.
    Process.sleep(1_100)
    assert TimelessBeamAcct.running?(name)
    assert %{recording: %{started: started}} = TimelessBeamAcct.status(name)
    assert started >= at
    assert_receive {:DOWN, ^ref, :process, ^sup, :shutdown}, 5_000

    assert [%{fields: %{"status" => "started"}}, %{fields: %{"status" => "ended"}}] =
             recorded(500)
  end

  test "a recording that is waiting can be called off" do
    name = name()
    {:ok, sup} = TimelessBeamAcct.start_link(options(name, start_at: "+1h", stop_after: "1h"))
    Process.unlink(sup)
    assert %{waiting: _} = TimelessBeamAcct.status(name)
    :ok = TimelessBeamAcct.stop(name)
    assert TimelessBeamAcct.status(name) == nil
    # It never began, and says nothing.
    assert recorded(300) == []
  end

  test "a recording begins later only if it is a recording, and within a week" do
    assert_raise ArgumentError, ~r/:start_at is for a recording/, fn ->
      Options.new!(start_at: "+1h")
    end

    assert_raise ArgumentError, ~r/a time within a week/, fn ->
      Options.new!(start_at: "+8d", stop_after: "1h")
    end

    assert_raise ArgumentError, ~r/:start_at/, fn ->
      Options.new!(start_at: "soon", stop_after: 1)
    end
  end

  test "how long a recording may run is checked when it starts" do
    assert_raise ArgumentError,
                 ~r/:stop_after is 2d00h, and a recording may run 1d00h at most/,
                 fn ->
                   Options.new!(stop_after: "48h")
                 end

    assert Options.new!(stop_after: "48h", max_recording: "72h").stop_after == 172_800.0
    assert Options.new!([]).max_recording == 86_400.0
    assert_raise ArgumentError, ~r/:stop_after/, fn -> Options.new!(stop_after: "never") end

    Application.put_env(:timeless_beam_acct, :max_recording, "48h")

    try do
      assert Options.new!(stop_after: "36h").max_recording == 172_800.0
    after
      Application.delete_env(:timeless_beam_acct, :max_recording)
    end
  end
end
