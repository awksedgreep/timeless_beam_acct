defmodule TimelessBeamAcct.ClockAheadTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.Clock

  test "a time of day that has passed is that time tomorrow" do
    now = Clock.parse!("2026-10-03 22:00")
    ahead = &Clock.format(elem(Clock.parse_ahead(&1, now), 1))

    assert ahead.("01:55") == "2026-10-04 01:55:00"
    assert ahead.("02:00:30") == "2026-10-04 02:00:30"
    # One still to come today is today.
    assert ahead.("23:30") == "2026-10-03 23:30:00"
    # Anything else is as it is written.
    assert ahead.("2026-10-05 02:00") == "2026-10-05 02:00:00"
    assert ahead.("-1h") == "2026-10-03 21:00:00"
    assert ahead.("+90m") == "2026-10-03 23:30:00"
    assert {:error, _} = Clock.parse_ahead("soon", now)
    assert {:error, _} = Clock.parse_ahead("+soon", now)
  end
end
