defmodule Mix.Tasks.TimelessBeamAcct do
  @shortdoc "Process accounting for a running BEAM: what the tasks are"

  @moduledoc """
  Process accounting for a node that is running.

  A collector is one of the processes of the node it accounts for. These
  tasks reach a node from a terminal: they put a collector into it, look
  at what the collector has, and take the collector out.

      mix timeless_beam_acct.check app@ohm --cookie secret
      mix timeless_beam_acct.attach app@ohm --cookie secret --sink http
      mix timeless_beam_acct.top app@ohm --cookie secret
      mix timeless_beam_acct.exits app@ohm --cookie secret --since -15m --failed
      mix timeless_beam_acct.trees app@ohm --cookie secret --failed
      mix timeless_beam_acct.detach app@ohm --cookie secret

  ## Reaching the node

  Every task takes the name of the node first, and then:

    * `--cookie`: the cookie of the node. Without it, the cookie of the
      user who runs the task is used, as `erl` would
    * `--as`: the name the task's own node takes. Without it, one is made
      up
    * `--collector`: the name the collector was started under, if it was
      started under one

  A node whose name has a dot in its host (`app@ohm.example.com`) is
  reached by long names, and any other by short ones.
  """

  use Mix.Task

  alias TimelessBeamAcct.{Options, Remote}

  @reach [cookie: :string, as: :string, collector: :string]

  @impl true
  def run(_args) do
    Mix.shell().info(@moduledoc)
  end

  @doc """
  The node named first among the arguments, reached, and what else was
  asked for: `{node, options}`. `switches` are those of the task, beside
  those every task has.

  Says what is wrong and ends the task, if the node cannot be reached or
  an argument is not understood.
  """
  @spec reach([String.t()], keyword(), String.t()) :: {node(), keyword()}
  def reach(args, switches, usage) do
    {given, rest, invalid} = OptionParser.parse(args, strict: @reach ++ switches)

    case {rest, invalid} do
      {[node], []} ->
        {reach, given} = Keyword.split(given, [:cookie, :as])

        case Remote.connect(node, reach) do
          {:ok, node} -> {node, named(given)}
          {:error, why} -> Mix.raise(why)
        end

      {_, [{switch, _} | _]} ->
        Mix.raise("#{switch} is not understood.\n\n    #{usage}")

      {_, []} ->
        Mix.raise("Which node?\n\n    #{usage}")
    end
  end

  defp named(given) do
    case Keyword.pop(given, :collector) do
      {nil, given} -> given
      {name, given} -> Keyword.put(given, :name, String.to_atom(name))
    end
  end

  @doc "End the task saying what went wrong, if something did."
  @spec done(:ok | {:ok, term()} | {:error, String.t()}) :: :ok
  def done(:ok), do: :ok
  def done({:ok, _}), do: :ok
  def done({:error, why}), do: Mix.raise(why)

  @doc """
  The switches that are options of a collector, by what each is given as.
  """
  @spec collector_switches() :: keyword()
  def collector_switches do
    for {key, value} <- Map.from_struct(%Options{}),
        key not in [:name, :exit_levels, :trace_roots, :long_message_queue],
        type = switch(key, value) do
      {key, type}
    end ++
      [metrics_url: :string, logs_url: :string, traces_url: :string, token: :string] ++
      [timeout: :string, backlog: :integer]
  end

  defp switch(:sink, _), do: :string
  defp switch(:records, _), do: :string
  defp switch(key, _) when key in [:host, :node], do: :string
  defp switch(key, _) when key in [:long_gc, :long_schedule, :large_heap], do: :integer
  defp switch(key, _) when key in [:sweep_budget, :notable_work], do: :float
  defp switch(_key, value) when is_boolean(value), do: :boolean
  defp switch(_key, value) when is_integer(value), do: :integer
  # A length of time, which is written: `30s`, `1h`.
  defp switch(_key, value) when is_float(value), do: :string
  defp switch(_key, _value), do: nil

  @doc "What was given for a collector, as the options it takes."
  @spec collector_options(keyword()) :: keyword()
  def collector_options(given) do
    Enum.map(given, fn
      {key, value} when key in [:sink, :records] -> {key, String.to_atom(value)}
      pair -> pair
    end)
  end
end
