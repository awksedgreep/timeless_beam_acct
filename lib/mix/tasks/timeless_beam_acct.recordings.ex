defmodule Mix.Tasks.TimelessBeamAcct.Recordings do
  @shortdoc "The recordings in a store: what was recorded, of which node, and how it ended"

  @moduledoc """
  The recordings a store has: collectors that were told how long to run,
  from the records each wrote of itself when it began and when it ended.
  See `TimelessBeamAcct.Recording`.

      mix timeless_beam_acct.recordings --logs-url http://127.0.0.1:9428
      mix timeless_beam_acct.recordings --logs-url http://planes:9428 --since -7d

    * `--logs-url`: the logs plane, which has the records
    * `--token` or `--logs-token`: a token that may read it
    * `--host`: only those of nodes on this host
    * `--since`: how far back, 7 days unless told

  Each is opened with `mix timeless_beam_acct.watch --recording ID`,
  given the planes.
  """

  use Mix.Task

  alias TimelessBeamAcct.{Clock, Human}
  alias TimelessBeamAcct.Watch.{Planes, Store}

  @switches [
    logs_url: :string,
    token: :string,
    logs_token: :string,
    host: :string,
    since: :string
  ]

  @impl true
  def run(args) do
    {given, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    case invalid do
      [{switch, _} | _] -> Mix.raise("#{switch} is not understood")
      [] -> :ok
    end

    unless given[:logs_url] do
      Mix.raise("Which logs plane? --logs-url, as http://127.0.0.1:9428")
    end

    now = Clock.now()

    since =
      case Clock.parse(given[:since] || "-7d", now) do
        {:ok, since} -> since
        {:error, why} -> Mix.raise(why)
      end

    with {:ok, planes} <- Planes.new(Keyword.drop(given, [:since])),
         {:ok, recordings} <- Store.recordings(planes, since, now) do
      Mix.shell().info(table(recordings, now))
    else
      {:error, why} -> Mix.raise(why)
    end
  end

  @doc false
  def table([], _now), do: "No recordings."

  def table(recordings, now) do
    rows =
      for r <- recordings do
        {how, length} =
          cond do
            r.ended -> {ended(r.reason), r.ended - r.started}
            r.stop_at > now -> {"running, until #{Clock.format(r.stop_at)}", now - r.started}
            true -> {"its node ended first", nil}
          end

        [
          String.slice(r.id, 0, 8),
          Clock.format(r.started),
          if(length, do: Human.duration(length), else: "-"),
          r.node,
          how,
          r.by || ""
        ]
      end

    headers = ["ID", "STARTED", "LENGTH", "NODE", "ENDED", "BY"]

    widths =
      for i <- 0..5, do: Enum.max(Enum.map([headers | rows], &String.length(Enum.at(&1, i))))

    Enum.map_join([headers | rows], "\n", fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
      |> String.trim_trailing()
    end)
  end

  defp ended("time"), do: "its time ran out"
  defp ended("stopped"), do: "it was stopped"
  defp ended(_), do: "what it ran in went first"
end
