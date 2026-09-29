defmodule Mix.Tasks.TimelessBeamAcct.Exits do
  @shortdoc "The processes of a node that ended"

  @moduledoc """
  Print the processes of a node that ended, from the records its
  collector keeps in memory.

      mix timeless_beam_acct.exits app@ohm --cookie secret --since -15m
      mix timeless_beam_acct.exits app@ohm --failed
      mix timeless_beam_acct.exits app@ohm --status killed
      mix timeless_beam_acct.exits app@ohm --group MyApp.Worker
      mix timeless_beam_acct.exits app@ohm --since -1h --summary --by app
      mix timeless_beam_acct.exits app@ohm --kind long_gc

    * `--since`, `--until`: by when the process ended: `-15m`, `14:30`,
      `"2026-09-29 03:12"`, or epoch seconds
    * `--status`, `--group`, `--app`: exactly
    * `--failed`: only those that failed
    * `--kind`: `exit` unless told; `any`, or `long_gc` and the like, for
      what the VM remarked on
    * `--limit`: the most recent
    * `--summary`: totals, by `--by`, which is `group` or `app`
    * `--width`: of the terminal

  The collector keeps its last two thousand records, unless it was told
  another number. What came before is in the stores.

  See `mix help timeless_beam_acct` for how the node is reached.
  """

  use Mix.Task

  alias Mix.Tasks.TimelessBeamAcct, as: Tasks
  alias TimelessBeamAcct.Remote

  @usage "mix timeless_beam_acct.exits NODE [--since TIME] [--failed] [--status STATUS] [--summary]"

  @switches [
    since: :string,
    until: :string,
    status: :string,
    group: :string,
    app: :string,
    failed: :boolean,
    kind: :string,
    limit: :integer,
    summary: :boolean,
    by: :string,
    width: :integer
  ]

  @impl true
  def run(args) do
    {node, given} = Tasks.reach(args, @switches, @usage)

    given =
      given
      |> Keyword.replace_lazy(:by, fn
        by when by in ["group", "app"] -> String.to_atom(by)
        by -> Mix.raise("--by is #{by}: expected group or app")
      end)
      |> Keyword.replace_lazy(:kind, fn
        "any" -> :any
        kind -> kind
      end)

    try do
      Tasks.done(Remote.exits(node, given))
    rescue
      error in ArgumentError -> Mix.raise(Exception.message(error))
    end
  end
end
