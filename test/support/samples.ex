defmodule TimelessBeamAcct.Samples do
  @moduledoc """
  Looking into a batch, for tests.
  """

  alias TimelessBeamAcct.Batch

  @doc "The value of the sample of this name whose labels include these, or `nil`."
  def value(%Batch{} = batch, name, labels \\ []) do
    case all(batch, name, labels) do
      [] -> nil
      [{_, _, value}] -> value
      several -> raise "#{length(several)} samples of #{name} have #{inspect(labels)}"
    end
  end

  @doc "The samples of this name whose labels include these."
  def all(%Batch{} = batch, name, labels \\ []) do
    wanted = Enum.map(labels, fn {key, value} -> {to_string(key), value} end)

    for {^name, has, _value} = sample <- Batch.samples(batch),
        Enum.all?(wanted, &(&1 in has)),
        do: sample
  end

  @doc "The values of one label, over the samples of this name."
  def labelled(%Batch{} = batch, name, label) do
    label = to_string(label)
    for {^name, labels, _} <- Batch.samples(batch), {^label, value} <- labels, do: value
  end

  @doc "The names of the metrics in a batch."
  def names(%Batch{} = batch),
    do: batch |> Batch.samples() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  @doc "Wait for something to be so."
  def wait_until(fun, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries == 0 -> raise "never happened"
      true -> Process.sleep(5) && wait_until(fun, tries - 1)
    end
  end
end
