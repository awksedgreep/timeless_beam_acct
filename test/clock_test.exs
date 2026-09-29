defmodule TimelessBeamAcct.ClockTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.Clock

  @now 1_790_000_000.0

  test "distances back from now" do
    assert Clock.parse("now", @now) == {:ok, @now}
    assert Clock.parse("-90s", @now) == {:ok, @now - 90.0}
    assert Clock.parse("-15m", @now) == {:ok, @now - 900.0}
    assert Clock.parse("-2h", @now) == {:ok, @now - 7200.0}
    assert Clock.parse("-1d", @now) == {:ok, @now - 86_400.0}
    assert Clock.parse("-45", @now) == {:ok, @now - 45.0}
  end

  test "epoch seconds are taken as they are" do
    assert Clock.parse("1753000000", @now) == {:ok, 1_753_000_000.0}
    assert Clock.parse(1_753_000_000, @now) == {:ok, 1_753_000_000.0}
    assert Clock.parse(~U[2025-07-20 08:26:40Z], @now) == {:ok, 1_753_000_000.0}
  end

  test "a written time formats back to itself" do
    # Whatever the zone, writing a local time and reading it back as a
    # local time is the identity.
    for text <- ["2026-09-29 14:30:05", "2026-01-15 00:00:00", "2026-06-30 23:59:59"] do
      assert Clock.format(Clock.parse!(text, @now)) == text
    end

    assert Clock.format(Clock.parse!("2026-09-29T14:30", @now)) == "2026-09-29 14:30:00"
    assert Clock.format(Clock.parse!("2026-09-29", @now)) == "2026-09-29 00:00:00"
  end

  test "a time of day is today" do
    today = @now |> Clock.format() |> String.slice(0, 10)
    assert Clock.format(Clock.parse!("14:30", @now)) == "#{today} 14:30:00"
  end

  test "what is not a time is refused" do
    for text <- ["", "yesterday", "-5x", "25:00", "2026-13", "12:00:00:00", "-", "2026-02-30"] do
      assert {:error, why} = Clock.parse(text, @now), "#{inspect(text)} was accepted"
      assert is_binary(why)
    end

    assert_raise ArgumentError, fn -> Clock.parse!("yesterday", @now) end
  end

  test "lengths of time" do
    assert Clock.parse_span("30") == {:ok, 30.0}
    assert Clock.parse_span("1.5h") == {:ok, 5400.0}
    assert Clock.parse_span(10) == {:ok, 10.0}
    assert Clock.parse_span(0.5) == {:ok, 0.5}
    assert {:error, _} = Clock.parse_span("h")
    assert {:error, _} = Clock.parse_span("")
    assert {:error, _} = Clock.parse_span("5w")
    assert {:error, _} = Clock.parse_span(-1)
  end

  test "ticks land on round times" do
    assert Clock.next_tick(1_790_000_003.2, 10) == 1_790_000_010.0
    # Strictly after: a reading taken on the tick waits for the next.
    assert Clock.next_tick(1_790_000_010.0, 10) == 1_790_000_020.0
    assert Clock.next_tick(1_790_000_010.0, 60) == 1_790_000_040.0
    # An interval shorter than a second is a second.
    assert Clock.next_tick(5.5, 0.1) == 6.0
  end
end
