defmodule TimelessBeamAcct.Recording do
  @moduledoc """
  A collector told how long to run: a recording, which ends by itself.

  A collector left running is not light on what it writes to. Per-process
  series come and go, and a store that is written to for days holds a
  great many of them (DESIGN.md, "How many series that is, over time").
  A collector is something run for a while and stopped, and a recording
  is that, with the stopping not left to anyone's memory.

      TimelessBeamAcct.start_link(sink: :http, stop_after: "1h")

  The timer is the collector's own, in the node. A page that started it
  may be closed, a terminal that started it may go, and the collector
  ends all the same. It ends as `TimelessBeamAcct.stop/1` ends it: what
  ended since the last sweep is accounted, and what the sink has waiting
  is written, and then it is gone. A collector among the children of a
  supervisor, and told `:stop_after`, is not started again by that
  supervisor when it ends so.

  ## What is written of it

  Two records, to the sink, beside the records of processes that ended:
  one when it begins and one when it ends, each with `kind` `recording`.
  They are what a list of the recordings of a store is made of.

  | field | |
  |---|---|
  | `status` | `started`, or `ended` |
  | `recording` | an id of the recording, the same in both |
  | `started`, `stop_at` | when it began, and when it is to end, in epoch seconds |
  | `stop_after`, `max_recording` | how long it was to run, and the most it could be made to |
  | `by` | who started it, if that was said |
  | `reason` | of `ended`: `time` (its time ran out), `stopped` (it was stopped), or `shutdown` (its node, or what started it, went first) |

  A node that ends without warning writes no `ended`. A recording with a
  `started` and nothing after it ended when its node did.

  ## Options

  | option | default | |
  |---|---|---|
  | `:stop_after` | | how long to run. Without it, a collector runs until it is stopped, and is not a recording |
  | `:max_recording` | `"24h"`, or the application's `:max_recording` | the longest a recording may be, at its start and by `extend/2` |
  | `:recorded_by` | | who started it, said in its records |
  """

  use GenServer

  alias TimelessBeamAcct.{Clock, Event, Human, Options, Tick, Writer}

  @doc false
  def child_spec(%Options{} = options) do
    %{
      id: :recording,
      start: {__MODULE__, :start_link, [options]},
      # Its ending is the collector's: the supervisor ends with it.
      restart: :transient,
      significant: true,
      shutdown: 30_000
    }
  end

  @doc false
  @spec start_link(Options.t()) :: GenServer.on_start()
  def start_link(%Options{} = options) do
    GenServer.start_link(__MODULE__, options, name: Options.name(options, :Recording))
  end

  @doc """
  When the collector of this name is to stop, and what is known of its
  recording; `nil` if it is not a recording, or is not running.
  """
  @spec status(atom()) :: map() | nil
  def status(name \\ TimelessBeamAcct) do
    GenServer.call(Options.name(name, :Recording), :status)
  catch
    :exit, _ -> nil
  end

  @doc """
  Run for `more` longer: a length of time, as `"1h"`. Refused past the
  most a recording may be. Returns when it is to stop now.
  """
  @spec extend(atom(), String.t() | number()) :: {:ok, float()} | {:error, String.t()}
  def extend(name \\ TimelessBeamAcct, more) do
    case Clock.parse_span(more) do
      {:ok, seconds} when seconds > 0 ->
        GenServer.call(Options.name(name, :Recording), {:extend, seconds})

      {:ok, _} ->
        {:error, "a recording is extended by more than no time"}

      {:error, why} ->
        {:error, why}
    end
  catch
    :exit, _ -> {:error, "no collector named #{inspect(name)} is recording"}
  end

  ## The process

  @impl true
  def init(%Options{stop_after: length} = options) do
    Process.flag(:trap_exit, true)
    started = Clock.now()
    stop_at = started + length

    state = %{
      options: options,
      id: id(options, started),
      started: started,
      stop_at: stop_at,
      timer: nil
    }

    write(state, "started", nil)
    {:ok, arm(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       recording: state.id,
       started: state.started,
       stop_at: state.stop_at,
       left: max(state.stop_at - Clock.now(), 0.0),
       max_recording: state.options.max_recording,
       by: state.options.recorded_by
     }, state}
  end

  def handle_call({:extend, seconds}, _from, state) do
    stop_at = state.stop_at + seconds
    most = state.started + state.options.max_recording

    if stop_at > most + 0.001 do
      {:reply,
       {:error,
        "a recording may run #{Human.duration(state.options.max_recording)} at most, " <>
          "and this one would run #{Human.duration(stop_at - state.started)}"}, state}
    else
      state = arm(%{state | stop_at: stop_at})
      {:reply, {:ok, stop_at}, state}
    end
  end

  @impl true
  def handle_info(:stop, state) do
    # A late timer of a time since moved: armed again for the new one.
    if Clock.now() + 0.05 < state.stop_at do
      {:noreply, arm(state)}
    else
      write(state, "ended", "time")
      Writer.flush(state.options)
      # A normal end of a significant child ends the supervisor, and with
      # it the collector, which accounts and flushes as it goes.
      {:stop, :normal, %{state | timer: nil}}
    end
  end

  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(:normal, %{timer: nil}), do: :ok

  def terminate(reason, state) do
    write(state, "ended", if(reason == :shutdown, do: "stopped", else: "shutdown"))
    Writer.flush(state.options)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp arm(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    wait = max(round((state.stop_at - Clock.now()) * 1000), 0)
    %{state | timer: Process.send_after(self(), :stop, wait)}
  end

  # The same recording has the same id, and another another.
  defp id(options, started) do
    "#{options.node}:#{round(started * 1_000_000)}"
    |> :erlang.md5()
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end

  defp write(state, status, reason) do
    %{options: options} = state
    now = Clock.now()

    fields =
      %{
        "kind" => "recording",
        "status" => status,
        "service" => "recording",
        "recording" => state.id,
        "started" => state.started,
        "stop_at" => state.stop_at,
        "stop_after" => options.stop_after,
        "max_recording" => options.max_recording
      }
      |> put("by", options.recorded_by)
      |> put("reason", reason)

    said =
      case status do
        "started" ->
          "recording #{state.id} started, to run #{Human.duration(state.stop_at - state.started)}"

        "ended" ->
          "recording #{state.id} ended after #{Human.duration(now - state.started)}: " <>
            ended(reason)
      end

    event = %Event{
      ts_us: round(now * 1_000_000),
      level: :notice,
      message: said,
      fields: fields
    }

    tick = %Tick{metrics: TimelessBeamAcct.Batch.new(round(now)), events: [event]}
    Writer.write(options, tick)
  end

  defp ended("time"), do: "its time ran out"
  defp ended("stopped"), do: "it was stopped"
  defp ended(_), do: "what it ran in went first"

  defp put(fields, _key, nil), do: fields
  defp put(fields, key, value), do: Map.put(fields, key, value)
end
