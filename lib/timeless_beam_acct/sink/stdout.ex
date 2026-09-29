defmodule TimelessBeamAcct.Sink.Stdout do
  @moduledoc """
  Print what would be stored. For looking at what the collector sees.

  What is printed is what the other sinks send, byte for byte: the samples
  as exposition text, the records as NDJSON, and the spans of a tick as one
  line of OTLP JSON. It comes from the same encoder, so what is read in a
  terminal is what a plane would have been given.

  ## Options

  | option | default | |
  |---|---|---|
  | `:device` | `:stdio` | where it is printed: a device as `IO.write/2` takes one |
  """

  @behaviour TimelessBeamAcct.Sink

  alias TimelessBeamAcct.{Encode, Tick}

  @type t :: %__MODULE__{device: IO.device()}

  defstruct device: :stdio

  @impl true
  @spec init(keyword()) :: {:ok, t()} | {:error, String.t()}
  def init(opts) when is_list(opts) do
    case Keyword.keys(opts) -- [:device] do
      [] ->
        device = Keyword.get(opts, :device, :stdio)

        if is_pid(device) or (is_atom(device) and not is_nil(device)),
          do: {:ok, %__MODULE__{device: device}},
          else: {:error, ":device is #{inspect(device)}: expected a device"}

      [unknown | _] ->
        {:error, "unknown option #{inspect(unknown)} of the :stdout sink"}
    end
  end

  @doc """
  Print the tick: its samples, then its records, then its spans.

  It is printed in one write, so the ticks of two collectors printing to
  one terminal do not run into each other.
  """
  @impl true
  @spec write(t(), String.t(), String.t(), Tick.t()) :: {:ok, t()} | {:error, term(), t()}
  def write(%__MODULE__{device: device} = state, host, node, %Tick{} = tick) do
    spans =
      case tick.spans do
        [] -> []
        spans -> [Encode.otlp_json(host, node, spans), ?\n]
      end

    text =
      IO.iodata_to_binary([
        Encode.prometheus_text(host, node, tick.metrics),
        Encode.ndjson(host, node, tick.events),
        spans
      ])

    case print(device, text) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{device: :stdio}), do: "stdout"
  def describe(%__MODULE__{device: device}), do: "stdout: to #{inspect(device)}"

  # Writing to a device that has gone raises. A terminal that was closed
  # is not a reason for the writer to end.
  defp print(_device, ""), do: :ok

  defp print(device, text) do
    IO.write(device, text)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
  end
end
