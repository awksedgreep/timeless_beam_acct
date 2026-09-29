defmodule TimelessBeamAcct.Clock do
  @moduledoc """
  Wall-clock times, as people write them and as the stores keep them.
  """

  @doc """
  A moment, in epoch seconds, from what was written:

    * `now`
    * a distance back from now: `-90s`, `-15m`, `-2h`, `-1d`
    * a local time today: `14:30`, `14:30:05`
    * a local date and time: `2026-09-29 14:30`, `2026-09-29T14:30:05`
    * a local date, meaning its first moment: `2026-09-29`
    * epoch seconds: `1790000000`

  A number is taken as epoch seconds, and a `DateTime` as the moment it is.
  """
  @spec parse(String.t() | number() | DateTime.t(), number()) ::
          {:ok, float()} | {:error, String.t()}
  def parse(written, now \\ now())

  def parse(%DateTime{} = moment, _now),
    do: {:ok, DateTime.to_unix(moment, :microsecond) / 1_000_000}

  def parse(seconds, _now) when is_number(seconds), do: {:ok, seconds / 1}

  def parse(written, now) when is_binary(written) do
    text = String.trim(written)

    cond do
      String.downcase(text) == "now" ->
        {:ok, now / 1}

      String.starts_with?(text, "-") ->
        with {:ok, back} <- parse_span(String.trim_leading(text, "-")) do
          {:ok, now - back}
        end

      text != "" and digits?(text) ->
        {:ok, String.to_integer(text) / 1}

      true ->
        parse_local(text, now)
    end
  end

  @doc "As `parse/2`, raising on what is not a time."
  @spec parse!(String.t() | number() | DateTime.t(), number()) :: float()
  def parse!(written, now \\ now()) do
    case parse(written, now) do
      {:ok, epoch} -> epoch
      {:error, why} -> raise ArgumentError, why
    end
  end

  defp parse_local(text, now) do
    {date, time} =
      case String.split(text, [" ", "T"], parts: 2) do
        [date, time] -> {date, time}
        [one] -> if String.contains?(one, ":"), do: {nil, one}, else: {one, nil}
      end

    with {:ok, date} <- parse_date(date, text, now),
         {:ok, time} <- parse_time(time, text),
         {:ok, epoch} <- local_to_epoch(date, time, text) do
      {:ok, epoch / 1}
    end
  end

  defp parse_date(nil, _text, now) do
    {date, _time} = local(now)
    {:ok, date}
  end

  defp parse_date(date, text, _now) do
    with [year, month, day] <- String.split(date, "-"),
         {:ok, [year, month, day]} <- integers([year, month, day]),
         true <- :calendar.valid_date(year, month, day) do
      {:ok, {year, month, day}}
    else
      _ -> {:error, "#{inspect(text)} is not a time: expected a date as YYYY-MM-DD"}
    end
  end

  defp parse_time(nil, _text), do: {:ok, {0, 0, 0}}

  defp parse_time(time, text) do
    parts =
      case String.split(time, ":") do
        [hour, minute] -> integers([hour, minute, "0"])
        [hour, minute, second] -> integers([hour, minute, second])
        _ -> :error
      end

    case parts do
      {:ok, [hour, minute, second]} when hour < 24 and minute < 60 and second < 60 ->
        {:ok, {hour, minute, second}}

      {:ok, _} ->
        {:error, "#{inspect(text)} is not a time of day"}

      :error ->
        {:error, "#{inspect(text)} is not a time: expected HH:MM or HH:MM:SS"}
    end
  end

  # The C library works out whether daylight saving applied then. An hour
  # that happened twice is taken as its first, and one that never happened
  # is refused.
  defp local_to_epoch(date, time, text) do
    case :calendar.local_time_to_universal_time_dst({date, time}) do
      [universal | _] ->
        {:ok, :calendar.datetime_to_gregorian_seconds(universal) - epoch_offset()}

      [] ->
        {:error, "#{inspect(text)} is not a time this system can represent"}
    end
  end

  @doc """
  A length of time, in seconds: `90s`, `15m`, `2h`, `1d`, or bare seconds.
  A number is taken as seconds.
  """
  @spec parse_span(String.t() | number()) :: {:ok, float()} | {:error, String.t()}
  def parse_span(seconds) when is_number(seconds) and seconds >= 0, do: {:ok, seconds / 1}

  def parse_span(seconds) when is_number(seconds),
    do: {:error, "#{inspect(seconds)} is not a length of time"}

  def parse_span(written) when is_binary(written) do
    text = String.trim(written)

    {number, unit} =
      case Regex.run(~r/\A(.*?)([A-Za-z])\z/s, text) do
        [_, number, unit] -> {number, unit}
        nil -> {text, "s"}
      end

    scale =
      case unit do
        "s" -> 1.0
        "m" -> 60.0
        "h" -> 3600.0
        "d" -> 86_400.0
        _ -> nil
      end

    case {number(number), scale} do
      {_, nil} ->
        {:error, "#{inspect(text)} is not a length of time: the unit is s, m, h, or d"}

      {{:ok, number}, scale} when number >= 0 ->
        {:ok, number * scale}

      {{:ok, _negative}, _} ->
        {:error, "#{inspect(text)} is not a length of time"}

      {:error, _} ->
        {:error, "#{inspect(text)} is not a length of time: expected a number and s, m, h, or d"}
    end
  end

  @doc "As `parse_span/1`, raising on what is not a length of time."
  @spec parse_span!(String.t() | number()) :: float()
  def parse_span!(written) do
    case parse_span(written) do
      {:ok, seconds} -> seconds
      {:error, why} -> raise ArgumentError, why
    end
  end

  @doc "`2026-09-29 14:30:05`, local time."
  @spec format(number()) :: String.t()
  def format(epoch) do
    {{year, month, day}, {hour, minute, second}} = local(epoch)

    [
      pad(year, 4),
      "-",
      pad(month),
      "-",
      pad(day),
      " ",
      pad(hour),
      ":",
      pad(minute),
      ":",
      pad(second)
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  The next multiple of `interval` strictly after `after_epoch`, in epoch
  seconds.

  Readings land on round times, so two nodes' lines are sampled at the same
  moments and a bucket boundary never splits an interval.
  """
  @spec next_tick(number(), number()) :: float()
  def next_tick(after_epoch, interval) do
    step = max(interval / 1, 1.0)
    (Float.floor(after_epoch / step) + 1.0) * step
  end

  @doc "Epoch seconds, now."
  @spec now() :: float()
  def now, do: System.os_time(:microsecond) / 1_000_000

  defp local(epoch) do
    (trunc(epoch) + epoch_offset())
    |> :calendar.gregorian_seconds_to_datetime()
    |> :calendar.universal_time_to_local_time()
  end

  defp epoch_offset, do: 62_167_219_200

  defp digits?(text), do: text =~ ~r/\A[0-9]+\z/

  defp integers(parts) do
    if Enum.all?(parts, &digits?/1) do
      {:ok, Enum.map(parts, &String.to_integer/1)}
    else
      :error
    end
  end

  defp number(text) do
    case Float.parse(text) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp pad(number, width \\ 2),
    do: number |> Integer.to_string() |> String.pad_leading(width, "0")
end
