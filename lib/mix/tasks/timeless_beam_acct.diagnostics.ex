defmodule Mix.Tasks.TimelessBeamAcct.Diagnostics do
  @shortdoc "What a report of a problem should have in it"

  @moduledoc """
  Print what someone who is asked about a problem will ask for: the
  versions, what the node lets a collector see, what the collector was
  told, and what it has counted.

      mix timeless_beam_acct.diagnostics app@ohm --cookie secret

  It is for pasting into a report. A bearer token is not printed.

  See `mix help timeless_beam_acct` for how the node is reached.
  """

  use Mix.Task

  alias Mix.Tasks.TimelessBeamAcct, as: Tasks
  alias TimelessBeamAcct.Remote

  @usage "mix timeless_beam_acct.diagnostics NODE [--cookie COOKIE] [--collector NAME]"

  @impl true
  def run(args) do
    {node, given} = Tasks.reach(args, [], @usage)
    Tasks.done(Remote.diagnostics(node, given))
  end
end
