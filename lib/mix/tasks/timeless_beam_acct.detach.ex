defmodule Mix.Tasks.TimelessBeamAcct.Detach do
  @shortdoc "Stop the collector that was put into a node"

  @moduledoc """
  Stop the collector that was put into a node, and take out what was put
  in with it.

      mix timeless_beam_acct.detach app@ohm --cookie secret

  What ended since the collector's last sweep is accounted, and what its
  sink has waiting is sent, before it stops.

  See `mix help timeless_beam_acct` for how the node is reached.
  """

  use Mix.Task

  alias Mix.Tasks.TimelessBeamAcct, as: Tasks
  alias TimelessBeamAcct.Remote

  @usage "mix timeless_beam_acct.detach NODE [--cookie COOKIE] [--collector NAME]"

  @impl true
  def run(args) do
    {node, given} = Tasks.reach(args, [], @usage)
    Tasks.done(Remote.detach(node, Keyword.get(given, :name, TimelessBeamAcct)))
    Mix.shell().info("The collector in #{node} has stopped.")
  end
end
