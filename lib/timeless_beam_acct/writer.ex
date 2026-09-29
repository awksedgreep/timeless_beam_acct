defmodule TimelessBeamAcct.Writer do
  @moduledoc """
  Hands each tick to the sink.

  It is a process of its own so that the sink can take its time. A plane
  that is unreachable takes as long to say so as it is given, and that
  must delay the next write and not the next reading: a reading that is
  late is a rate over the wrong interval.

  Between two ticks it has nothing to do, and sleeps: what it used to
  encode a tick is given back, and not kept until the next.

  A sink that fails is said to have failed once, and then again every so
  often while it keeps failing, and once more when it is storing again.
  A collector that logged every failed write would fill the log of the
  application it is there to watch.
  """

  use GenServer

  require Logger

  alias TimelessBeamAcct.{Options, Tick}

  # How often a failure that keeps happening is mentioned again.
  @repeat_every 30
  # Ticks that may wait to be written before the next is let go instead.
  @most_waiting 32

  @spec start_link(Options.t()) :: GenServer.on_start()
  def start_link(%Options{} = options) do
    GenServer.start_link(__MODULE__, options, name: Options.name(options, :Writer))
  end

  @doc """
  Hand over what a tick produced. Returns at once.

  `:dropped` if the writer has more waiting than it should, which is a
  sink that takes longer over a tick than a tick takes to come: the tick
  is let go, since what the writer cannot keep up with it cannot catch up
  with either.
  """
  @spec write(Options.t() | atom(), Tick.t()) :: :ok | :dropped
  def write(name, %Tick{} = tick) do
    with pid when is_pid(pid) <- Process.whereis(Options.name(name, :Writer)),
         {:message_queue_len, waiting} when waiting < @most_waiting <-
           Process.info(pid, :message_queue_len) do
      GenServer.cast(pid, {:write, tick})
    else
      _ -> :dropped
    end
  end

  @doc "Make everything written so far survive a crash, and wait until it has been."
  @spec flush(Options.t() | atom(), timeout()) :: :ok | {:error, term()}
  def flush(name, timeout \\ 30_000) do
    GenServer.call(Options.name(name, :Writer), :flush, timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "What the writer has to say of itself: the sink, and how it is doing."
  @spec status(Options.t() | atom()) :: map() | nil
  def status(name) do
    GenServer.call(Options.name(name, :Writer), :status, 5_000)
  catch
    :exit, _ -> nil
  end

  ## The process

  @impl true
  def init(%Options{sink: {module, opts}} = options) do
    Process.flag(:trap_exit, true)

    case module.init(opts) do
      {:ok, sink} ->
        state = %{
          options: options,
          module: module,
          sink: sink,
          written: 0,
          failures: 0,
          failed: 0,
          last_error: nil
        }

        schedule_flush(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:sink, reason}}
    end
  end

  @impl true
  def handle_cast({:write, tick}, state) do
    %{options: options} = state

    attempted =
      attempt(state, "write", fn sink ->
        state.module.write(sink, options.host, options.node, tick)
      end)

    # Written is what the sink took. What it did not is counted as failed.
    written = if attempted.failed == state.failed, do: state.written + 1, else: state.written
    {:noreply, %{attempted | written: written}, :hibernate}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, flush_sink(state)}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       sink: state.module.describe(state.sink),
       written: state.written,
       failed: state.failed,
       failing: state.failures > 0,
       last_error: state.last_error
     }, state}
  end

  @impl true
  def handle_info(:flush, state) do
    schedule_flush(state)
    {:noreply, flush_sink(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = flush_sink(state)

    if function_exported?(state.module, :close, 1) do
      safely(fn -> state.module.close(state.sink) end)
    end

    :ok
  end

  defp schedule_flush(state),
    do: Process.send_after(self(), :flush, round(state.options.flush_interval * 1000))

  defp flush_sink(state) do
    if function_exported?(state.module, :flush, 1),
      do: attempt(state, "flush", fn sink -> state.module.flush(sink) end),
      else: state
  end

  # A sink is someone else's code, talking to someone else's server. What
  # it raises is a failed write, and not the end of the writer.
  defp attempt(state, what, call) do
    case safely(fn -> call.(state.sink) end) do
      {:ok, sink} ->
        if state.failures > 0 do
          Logger.info("timeless_beam_acct: storing again after #{state.failures} failed writes")
        end

        %{state | sink: sink, failures: 0}

      {:error, reason, sink} ->
        failed(%{state | sink: sink}, what, reason)

      {:raised, reason} ->
        failed(state, what, reason)

      other ->
        failed(state, what, "the sink answered #{inspect(other, limit: 5)}")
    end
  end

  defp failed(state, what, reason) do
    reason = if is_binary(reason), do: reason, else: inspect(reason, limit: 10)

    if rem(state.failures, @repeat_every) == 0 do
      Logger.warning("timeless_beam_acct: #{what} failed: #{reason}")
    end

    %{state | failures: state.failures + 1, failed: state.failed + 1, last_error: reason}
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:raised, Exception.message(error)}
  catch
    kind, reason -> {:raised, "#{kind}: #{inspect(reason, limit: 10)}"}
  end
end
