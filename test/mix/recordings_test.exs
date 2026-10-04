defmodule Mix.Tasks.TimelessBeamAcct.RecordingsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.TimelessBeamAcct.Recordings

  test "recordings are a table, the last first, with how each ended" do
    now = 100_000.0

    recordings = [
      %{
        id: "aaaaaaaaaaaa",
        node: "a@x",
        host: "x",
        started: now - 600,
        stop_at: now + 3000,
        ended: nil,
        reason: nil,
        by: "mark@x"
      },
      %{
        id: "bbbbbbbbbbbb",
        node: "b@x",
        host: "x",
        started: now - 9000,
        stop_at: now - 5400,
        ended: now - 5400,
        reason: "time",
        by: nil
      },
      %{
        id: "cccccccccccc",
        node: "c@x",
        host: "x",
        started: now - 20000,
        stop_at: now - 16400,
        ended: nil,
        reason: nil,
        by: nil
      }
    ]

    [header, running, done, lost] = String.split(Recordings.table(recordings, now), "\n")
    assert header =~ ~r/^ID\s+STARTED\s+LENGTH\s+NODE\s+ENDED\s+BY$/
    assert running =~ ~r/^aaaaaaaa .* 10m00s\s+a@x\s+running, until .* mark@x$/
    assert done =~ ~r/^bbbbbbbb .* 1h00m\s+b@x\s+its time ran out$/
    assert lost =~ ~r/^cccccccc .* -\s+c@x\s+its node ended first$/
    assert Recordings.table([], now) == "No recordings."
  end

  test "a logs plane is to be said" do
    assert_raise Mix.Error, ~r/Which logs plane\?/, fn -> Recordings.run([]) end

    assert_raise Mix.Error, ~r/--loggs-url is not understood/, fn ->
      Recordings.run(["--loggs-url", "x"])
    end
  end
end
