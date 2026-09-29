defmodule TimelessBeamAcct.FakeStores do
  @moduledoc """
  What the fake stores of one test were given, and what they were told to
  do about it.

  A test calls `start/0`, which starts an agent named after the test's
  process. A fake finds it by the process that called it, or by the
  `$callers` of that process, which is where `Task` and the sink put the
  one they are working for. So tests that use the fakes may run at the
  same time.

  A fake does as it was told with `tell/3`:

  | told | it |
  |---|---|
  | `:ok` | stores, which is what it does untold |
  | `{:error, reason}` | answers that |
  | `{:answer, term}` | answers that |
  | `:raise` | raises |
  | `:exit` | exits, as `GenServer.call/3` does when there is no process |
  | `:hang` | never answers |
  | `:break_link` | is killed by a process it was linked to |
  """

  @type store :: :metrics | :logs | :traces | :unflushed

  @doc "Start recording for the calling test. To be called from the test's process."
  @spec start() :: :ok
  def start do
    {:ok, _pid} =
      ExUnit.Callbacks.start_supervised(%{
        id: __MODULE__,
        start: {Agent, :start_link, [fn -> %{calls: [], told: %{}} end, [name: name(self())]]}
      })

    :ok
  end

  @doc "What is done the next times `function` of `store` is called."
  @spec tell(store(), atom(), term()) :: :ok
  def tell(store, function, what) do
    Agent.update(agent!(), &put_in(&1, [:told, {store, function}], what))
  end

  @doc "Every call made, oldest first, as `{store, function, arguments}`."
  @spec calls() :: [{store(), atom(), [term()]}]
  def calls, do: Agent.get(agent!(), &Enum.reverse(&1.calls))

  @doc "The calls made of one store."
  @spec calls(store()) :: [{atom(), [term()]}]
  def calls(store) do
    for {^store, function, arguments} <- calls(), do: {function, arguments}
  end

  @doc "A call of a fake: recorded, and answered as was told."
  @spec called(store(), atom(), [term()]) :: term()
  def called(store, function, arguments) do
    told =
      Agent.get_and_update(agent!(), fn state ->
        {Map.get(state.told, {store, function}, :ok),
         %{state | calls: [{store, function, arguments} | state.calls]}}
      end)

    act(told, store, function)
  end

  @doc "What was told of a function that is asked and not recorded, like `running?`."
  @spec told(store(), atom(), term()) :: term()
  def told(store, function, default) do
    Agent.get(agent!(), &Map.get(&1.told, {store, function}, default))
  end

  defp act(:ok, _store, _function), do: :ok
  defp act({:error, _} = error, _store, _function), do: error
  defp act({:answer, answer}, _store, _function), do: answer
  defp act(:raise, store, function), do: raise("the fake #{store} store raised in #{function}")

  defp act(:exit, store, function),
    do: exit({:noproc, {GenServer, :call, [:"fake_#{store}", function, 5000]}})

  defp act(:hang, _store, _function), do: Process.sleep(:infinity)

  defp act(:break_link, _store, _function) do
    spawn_link(fn -> exit(:the_linked_process_died) end)
    Process.sleep(:infinity)
  end

  defp agent! do
    [self() | Process.get(:"$callers", [])]
    |> Enum.map(&name/1)
    |> Enum.find(&Process.whereis/1) ||
      raise "no fake stores for this process: call TimelessBeamAcct.FakeStores.start/0 in the test"
  end

  defp name(pid) when is_pid(pid), do: :"#{__MODULE__}.#{:erlang.pid_to_list(pid)}"
end

defmodule TimelessBeamAcct.FakeMetrics do
  @moduledoc "Stands for `TimelessMetrics`: `write_batch/2`, `flush/1`, and whether it is running."

  alias TimelessBeamAcct.FakeStores

  def write_batch(store, entries), do: FakeStores.called(:metrics, :write_batch, [store, entries])
  def flush(store), do: FakeStores.called(:metrics, :flush, [store])
  def running?(_store), do: FakeStores.told(:metrics, :running?, true)
end

defmodule TimelessBeamAcct.FakeLogs do
  @moduledoc "Stands for `TimelessLogs`: `ingest/1`, `flush/0`, and whether it is running."

  alias TimelessBeamAcct.FakeStores

  def ingest(entries), do: FakeStores.called(:logs, :ingest, [entries])
  def flush, do: FakeStores.called(:logs, :flush, [])
  def running?, do: FakeStores.told(:logs, :running?, true)
end

defmodule TimelessBeamAcct.FakeTraces do
  @moduledoc "Stands for a module put before `TimelessTraces`, which takes spans itself."

  alias TimelessBeamAcct.FakeStores

  def ingest(spans), do: FakeStores.called(:traces, :ingest, [spans])
  def flush, do: FakeStores.called(:traces, :flush, [])
  def running?, do: FakeStores.told(:traces, :running?, true)
end

defmodule TimelessBeamAcct.FakeTracesLibrary do
  @moduledoc """
  Stands for `TimelessTraces` as it is: it flushes, and takes spans in the
  `StorageEngine` beneath it.
  """

  alias TimelessBeamAcct.FakeStores

  def flush, do: FakeStores.called(:traces, :flush, [])

  defmodule StorageEngine do
    @moduledoc false

    def ingest(spans), do: TimelessBeamAcct.FakeStores.called(:traces, :ingest, [spans])
  end
end

defmodule TimelessBeamAcct.FakeWithoutFlush do
  @moduledoc "A store that takes records or spans and has no flush."

  alias TimelessBeamAcct.FakeStores

  def ingest(items), do: FakeStores.called(:unflushed, :ingest, [items])
end

defmodule TimelessBeamAcct.FakeWithNothing do
  @moduledoc "A module that is loaded and exports none of what a store does."

  def hello, do: :world
end
