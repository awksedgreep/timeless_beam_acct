defmodule Mix.Tasks.TimelessBeamAcct.Trees do
  @shortdoc "The jobs of a node, as the trees of processes they were"

  @moduledoc """
  Print the jobs of a node, as the trees of processes they were, from the
  spans its collector keeps in memory.

      mix timeless_beam_acct.trees app@ohm --cookie secret --since -15m
      mix timeless_beam_acct.trees app@ohm --failed
      mix timeless_beam_acct.trees app@ohm --group MyApp.Worker --width 0

    * `--since`, `--until`: by when the job started
    * `--group`, `--app`: jobs in which a process of that group, or of
      that application, took part
    * `--failed`: jobs in which something failed
    * `--limit`: the most recent
    * `--width`: of the terminal; `0` for no limit
    * `--max-lines`: of one tree

  See `mix help timeless_beam_acct` for how the node is reached.
  """

  use Mix.Task

  alias Mix.Tasks.TimelessBeamAcct, as: Tasks
  alias TimelessBeamAcct.Remote

  @usage "mix timeless_beam_acct.trees NODE [--since TIME] [--failed] [--group GROUP]"

  @switches [
    since: :string,
    until: :string,
    group: :string,
    app: :string,
    failed: :boolean,
    limit: :integer,
    width: :integer,
    max_lines: :integer
  ]

  @impl true
  def run(args) do
    {node, given} = Tasks.reach(args, @switches, @usage)

    try do
      Tasks.done(Remote.trees(node, given))
    rescue
      error in ArgumentError -> Mix.raise(Exception.message(error))
    end
  end
end
