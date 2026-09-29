defmodule Mix.Tasks.TimelessBeamAcct.Attach do
  @shortdoc "Put a collector into a running node"

  @moduledoc """
  Put a collector into a node that is running, and start it.

      mix timeless_beam_acct.attach app@ohm --cookie secret --sink http
      mix timeless_beam_acct.attach app@ohm --sink http --metrics-url http://planes:8428 \\
          --min-age 1m --no-traces

  Nothing is installed in the node and nothing is restarted: the
  collector's modules are sent to it and loaded. The collector stays when
  this task ends, until it is detached or the node ends.

  The node has to have Elixir in it, no older than the Elixir and the OTP
  this task runs on.

  Every option of a collector can be given, written with dashes:
  `--process-interval 30s`, `--max-processes 500`, `--no-exits`. See
  `TimelessBeamAcct.Options`. And see `mix help timeless_beam_acct` for
  how the node is reached.
  """

  use Mix.Task

  alias Mix.Tasks.TimelessBeamAcct, as: Tasks
  alias TimelessBeamAcct.Remote

  @usage "mix timeless_beam_acct.attach NODE [--cookie COOKIE] [--sink http|timeless|stdout] ..."

  @impl true
  def run(args) do
    {node, given} = Tasks.reach(args, Tasks.collector_switches(), @usage)

    case Remote.attach(node, Tasks.collector_options(given)) do
      {:ok, _collector} ->
        Mix.shell().info("A collector is running in #{node}.")
        Tasks.done(Remote.check(node, Keyword.take(given, [:name])))

      {:error, why} ->
        Mix.raise(why)
    end
  end
end
