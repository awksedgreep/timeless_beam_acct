defmodule TimelessBeamAcct.Recording.Waiting do
  @moduledoc """
  A recording that is to begin later: it waits, reading nothing, and at
  `:start_at` starts the collector it is the first child of. See
  `TimelessBeamAcct.Recording`.
  """

  use GenServer

  alias TimelessBeamAcct.{Clock, Options}
  alias TimelessBeamAcct.Supervisor, as: Collector

  @doc false
  def child_spec(%Options{} = options) do
    %{id: :waiting, start: {__MODULE__, :start_link, [options]}, restart: :transient}
  end

  @doc false
  @spec start_link(Options.t()) :: GenServer.on_start()
  def start_link(%Options{} = options) do
    GenServer.start_link(__MODULE__, options, name: Options.name(options, :Waiting))
  end

  @doc """
  When the recording of this name is to begin, and how long it is to run;
  `nil` if none is waiting.
  """
  @spec status(atom()) :: %{start_at: float(), stop_after: float(), by: String.t() | nil} | nil
  def status(name \\ TimelessBeamAcct) do
    GenServer.call(Options.name(name, :Waiting), :status)
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(%Options{} = options) do
    wait = max(round((options.start_at - Clock.now()) * 1000), 0)
    Process.send_after(self(), :begin, wait)
    {:ok, options}
  end

  @impl true
  def handle_call(:status, _from, options) do
    {:reply,
     %{start_at: options.start_at, stop_after: options.stop_after, by: options.recorded_by},
     options}
  end

  @impl true
  def handle_info(:begin, options) do
    # Started by the supervisor this is a child of, which is not waiting
    # on this, and is free to start them.
    supervisor = Options.name(options, :Supervisor)

    Enum.each(Collector.children(options), fn child ->
      {:ok, _} = Supervisor.start_child(supervisor, child)
    end)

    {:stop, :normal, options}
  end
end
