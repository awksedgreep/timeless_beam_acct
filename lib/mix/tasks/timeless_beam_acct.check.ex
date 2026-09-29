defmodule Mix.Tasks.TimelessBeamAcct.Check do
  @shortdoc "What a node lets a collector see"

  @moduledoc """
  Say what a node lets a collector see, and how the collector in it is
  doing, if there is one.

      mix timeless_beam_acct.check app@ohm --cookie secret

  See `mix help timeless_beam_acct` for how the node is reached.
  """

  use Mix.Task

  alias Mix.Tasks.TimelessBeamAcct, as: Tasks
  alias TimelessBeamAcct.Remote

  @usage "mix timeless_beam_acct.check NODE [--cookie COOKIE] [--collector NAME]"

  @impl true
  def run(args) do
    {node, given} = Tasks.reach(args, [], @usage)
    Tasks.done(Remote.check(node, given))
  end
end
