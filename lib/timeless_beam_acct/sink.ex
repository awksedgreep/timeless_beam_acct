defmodule TimelessBeamAcct.Sink do
  @moduledoc """
  Where samples, records, and spans go.

  A sink is a module and the state it keeps. It is called from one process,
  the writer, which is not the process that collects: a plane that takes
  five seconds to refuse a connection delays the next write and not the
  next reading.

  | sink | is |
  |---|---|
  | `TimelessBeamAcct.Sink.Http` | the Timeless planes, which is what a canvas reads |
  | `TimelessBeamAcct.Sink.Timeless` | the Timeless stores running in this node |
  | `TimelessBeamAcct.Sink.Stdout` | the terminal |
  | `TimelessBeamAcct.Sink.Forward` | a process, as messages |
  """

  alias TimelessBeamAcct.Tick

  @type state :: term()

  @doc "Make the sink from its options. Nothing is sent yet."
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Store what one tick produced.

  On an error the state is still returned: a sink that keeps what it could
  not send has more in it after a failure than before.
  """
  @callback write(state(), host :: String.t(), node :: String.t(), Tick.t()) ::
              {:ok, state()} | {:error, term(), state()}

  @doc "Make everything written so far survive a crash."
  @callback flush(state()) :: {:ok, state()} | {:error, term(), state()}

  @doc "Whatever a clean shutdown owes the store, after the last flush."
  @callback close(state()) :: :ok

  @doc "A line for the startup banner."
  @callback describe(state()) :: String.t()

  @optional_callbacks flush: 1, close: 1

  @doc "The module a sink is named by."
  @spec module(atom()) :: module()
  def module(:http), do: TimelessBeamAcct.Sink.Http
  def module(:timeless), do: TimelessBeamAcct.Sink.Timeless
  def module(:stdout), do: TimelessBeamAcct.Sink.Stdout
  def module(:forward), do: TimelessBeamAcct.Sink.Forward
  def module(module) when is_atom(module), do: module
end
