defmodule Mix.Tasks.TimelessBeamAcct.Top do
  @shortdoc "The processes of a node that are doing the most"

  @moduledoc """
  Print the processes of a node that are doing the most, as of the
  collector's last sweep.

      mix timeless_beam_acct.top app@ohm --cookie secret
      mix timeless_beam_acct.top app@ohm --sort memory -n 10
      mix timeless_beam_acct.top app@ohm --app my_app

    * `--sort`: `work` (the default), `memory`, `queue`, or `age`
    * `-n`: how many, 20 unless told
    * `--app`, `--group`: only those of an application, or of a group

  See `mix help timeless_beam_acct` for how the node is reached.
  """

  use Mix.Task

  alias Mix.Tasks.TimelessBeamAcct, as: Tasks
  alias TimelessBeamAcct.Remote

  @usage "mix timeless_beam_acct.top NODE [--sort work|memory|queue|age] [-n COUNT] [--app APP]"
  @sorts ~w(work memory queue age)

  @impl true
  def run(args) do
    args = Enum.map(args, &if(&1 == "-n", do: "--n", else: &1))

    {node, given} =
      Tasks.reach(args, [sort: :string, n: :integer, app: :string, group: :string], @usage)

    given =
      Keyword.replace_lazy(given, :sort, fn sort ->
        if sort in @sorts,
          do: String.to_atom(sort),
          else: Mix.raise("--sort is #{sort}: expected one of #{Enum.join(@sorts, ", ")}")
      end)

    Tasks.done(Remote.top(node, given))
  end
end
