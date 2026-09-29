defmodule TimelessBeamAcct.Human do
  @moduledoc """
  Figures as people read them, in the messages of records and in what
  `TimelessBeamAcct.Report` prints.

  They are written as timeless-acct writes them, digit for digit, so that a
  record of a process of a node and a record of a process of its host read
  alike. One thing is added: a length of time under a millisecond is
  written in microseconds. A process of a host that lived for less is
  rare, and a process of a node that lived for more is.
  """

  @doc """
  A length of time, as it is said: `250µs`, `340ms`, `12.5s`, `4m07s`,
  `2h03m`, `1d01h`.

  A length below zero is none.

      iex> TimelessBeamAcct.Human.duration(247)
      "4m07s"
  """
  @spec duration(number()) :: String.t()
  def duration(seconds) when is_number(seconds) do
    seconds = max(seconds / 1, 0.0)

    cond do
      seconds == 0.0 ->
        "0ms"

      seconds < 0.000_999_5 ->
        fixed(seconds * 1_000_000.0, 0) <> "µs"

      seconds < 1.0 ->
        fixed(seconds * 1000.0, 0) <> "ms"

      seconds < 60.0 ->
        fixed(seconds, 1) <> "s"

      seconds < 3600.0 ->
        "#{trunc(seconds / 60.0)}m#{two(:math.fmod(seconds, 60.0))}s"

      seconds < 86_400.0 ->
        "#{trunc(seconds / 3600.0)}h#{two(:math.fmod(seconds, 3600.0) / 60.0)}m"

      true ->
        "#{trunc(seconds / 86_400.0)}d#{two(:math.fmod(seconds, 86_400.0) / 3600.0)}h"
    end
  end

  @doc """
  A size, in the units of memory: `512 B`, `12.0 KiB`, `340 MiB`,
  `1.5 GiB`.

      iex> TimelessBeamAcct.Human.bytes(1536 * 1024 * 1024)
      "1.5 GiB"
  """
  @spec bytes(number()) :: String.t()
  def bytes(bytes) when is_number(bytes) do
    scaled(max(trunc(bytes), 0) / 1, ["B", "KiB", "MiB", "GiB", "TiB"])
  end

  defp scaled(value, [_unit | [_ | _] = larger]) when value >= 1024.0,
    do: scaled(value / 1024.0, larger)

  defp scaled(value, [unit | _]) do
    if unit == "B" or value >= 100.0 do
      "#{fixed(value, 0)} #{unit}"
    else
      "#{fixed(value, 1)} #{unit}"
    end
  end

  @doc """
  A count, in thousands: `999`, `12.4k`, `1.2M`, `3.4G`.

  Below a thousand an integer is written as it is, and a float to one
  decimal place unless it is whole. From a hundred of a unit up, the
  decimal place is dropped, as `bytes/1` drops it: `182k`.

      iex> TimelessBeamAcct.Human.count(12_400)
      "12.4k"
  """
  @spec count(number()) :: String.t()
  def count(count) when is_number(count) and count < 0,
    do: "-" <> count(-count)

  def count(count) when is_integer(count) and count < 1000,
    do: Integer.to_string(count)

  def count(count) when is_number(count),
    do: thousands(count / 1, ["", "k", "M", "G", "T"])

  defp thousands(value, [_unit | [_ | _] = larger]) when value >= 1000.0,
    do: thousands(value / 1000.0, larger)

  defp thousands(value, [unit | larger]) do
    tenths = fixed(value, 1)

    text =
      cond do
        unit == "" and value == Float.floor(value) -> fixed(value, 0)
        # From a hundred up, once it is rounded: 99.96 is `100`.
        unit != "" and String.length(tenths) > 4 -> fixed(value, 0)
        true -> tenths
      end

    # 999.96 is a thousand once it is rounded, and is written as one.
    if larger != [] and text in ["1000", "1000.0"] do
      thousands(1.0, larger)
    else
      text <> unit
    end
  end

  # A number to so many decimal places, rounded as the Rust formats a
  # float: from the number the float is exactly, and a tie to the even
  # digit. The VM's own formatting rounds 0.25 to 0.3 and the Rust to 0.2.
  @doc """
  A number to so many decimal places: `fixed(12.44, 1)` is `12.4`.
  """
  @spec fixed(number(), non_neg_integer()) :: String.t()
  def fixed(value, places) when value < 0, do: "-" <> fixed(-value, places)

  def fixed(value, places) do
    {numerator, denominator} = Float.ratio(value / 1)
    scale = Integer.pow(10, places)
    whole = div(numerator * scale, denominator)
    twice = 2 * rem(numerator * scale, denominator)

    rounded =
      cond do
        twice > denominator -> whole + 1
        twice < denominator -> whole
        rem(whole, 2) == 0 -> whole
        true -> whole + 1
      end

    if places == 0 do
      Integer.to_string(rounded)
    else
      decimals = rounded |> rem(scale) |> Integer.to_string() |> String.pad_leading(places, "0")
      "#{div(rounded, scale)}.#{decimals}"
    end
  end

  defp two(number),
    do: number |> trunc() |> Integer.to_string() |> String.pad_leading(2, "0")
end
