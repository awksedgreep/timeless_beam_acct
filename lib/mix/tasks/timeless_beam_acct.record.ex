defmodule Mix.Tasks.TimelessBeamAcct.Record do
  @shortdoc "Record a running node for a while: a collector that ends by itself"

  @moduledoc """
  Record a node: put a collector into it that ends by itself when its
  time is up. See `TimelessBeamAcct.Recording`.

      mix timeless_beam_acct.record app@ohm --cookie secret --for 1h
      mix timeless_beam_acct.record app@ohm --for 8h --metrics-url http://planes:8428 ...
      mix timeless_beam_acct.record app@ohm --extend 30m
      mix timeless_beam_acct.record app@ohm --stop

  `--for` is how long, an hour unless told, and a day at most unless
  `--max-recording` says more. The collector's timer is in the node: the
  recording ends when it is to whether or not this terminal is still
  there. While it runs, `mix timeless_beam_acct.watch` looks at it.

  `--extend` makes a recording that is running run longer, and `--stop`
  ends it now.

  Every option of a collector can be given, as with `attach`, and the
  node is reached as every task reaches it: `mix help timeless_beam_acct`.
  """

  use Mix.Task

  alias Mix.Tasks.TimelessBeamAcct, as: Tasks
  alias TimelessBeamAcct.{Clock, Human, Remote}

  @usage "mix timeless_beam_acct.record NODE [--for 1h] [--extend 30m] [--stop] [--cookie COOKIE] ..."

  @impl true
  def run(args) do
    switches = [for: :string, extend: :string, stop: :boolean] ++ Tasks.collector_switches()
    {node, given} = Tasks.reach(args, switches, @usage)
    {name, given} = Keyword.pop(given, :name, TimelessBeamAcct)

    cond do
      given[:stop] ->
        Tasks.done(Remote.detach(node, name))
        Mix.shell().info("The recording of #{node} has stopped.")

      more = given[:extend] ->
        case Remote.extend(node, more, name) do
          {:ok, stop_at} ->
            Mix.shell().info("The recording of #{node} now ends at #{Clock.format(stop_at)}.")

          {:error, why} ->
            Mix.raise(why)
        end

      true ->
        record(node, name, given)
    end
  end

  defp record(node, name, given) do
    {length, given} = Keyword.pop(given, :for, "1h")

    opts =
      given
      |> Keyword.drop([:stop, :extend])
      |> Tasks.collector_options()
      |> Keyword.merge(name: name, stop_after: length)
      |> Keyword.put_new(:recorded_by, by())

    case Remote.attach(node, opts) do
      {:ok, _collector} ->
        case Remote.status(node, name) do
          {:ok, %{recording: %{stop_at: stop_at, started: started}}} ->
            Mix.shell().info(
              "Recording #{node} for #{Human.duration(stop_at - started)}, until #{Clock.format(stop_at)}. " <>
                "It ends by itself.\n\n" <>
                "    mix timeless_beam_acct.watch #{node}             to look at it\n" <>
                "    mix timeless_beam_acct.record #{node} --extend 1h  to make it longer\n" <>
                "    mix timeless_beam_acct.record #{node} --stop       to end it now"
            )

          _ ->
            Mix.shell().info("Recording #{node}.")
        end

      {:error, why} ->
        Mix.raise(why)
    end
  end

  defp by do
    user = System.get_env("USER") || System.get_env("USERNAME")
    host = TimelessBeamAcct.Options.hostname()
    if user, do: "#{user}@#{host}", else: host
  end
end
