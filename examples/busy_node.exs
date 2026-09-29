# A node with something going on in it, to point a collector at.
#
#     elixir --sname busy --cookie busy examples/busy_node.exs
#
# and from another terminal:
#
#     mix timeless_beam_acct.attach busy@$(hostname -s) --cookie busy --sink stdout
#     mix timeless_beam_acct.top busy@$(hostname -s) --cookie busy
#     mix timeless_beam_acct.trees busy@$(hostname -s) --cookie busy --failed
#
# It answers "requests": each is a process that a supervisor starts, which
# asks a cache, starts a few tasks, and now and then fails.

defmodule Busy.Cache do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @impl true
  def init(:ok) do
    table = :ets.new(:busy_cache, [:named_table, :set, :protected])
    for n <- 1..20_000, do: :ets.insert(table, {n, :binary.copy(<<n::32>>, 16)})
    {:ok, table}
  end

  @impl true
  def handle_call({:get, key}, _from, table) do
    {:reply, :ets.lookup(table, key), table}
  end
end

defmodule Busy.Hoarder do
  @moduledoc "Holds on to what it is sent, as a process with a leak does."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(held), do: {:ok, held}

  @impl true
  def handle_cast({:keep, thing}, held), do: {:noreply, [thing | Enum.take(held, 20_000)]}
end

defmodule Busy.Request do
  def handle(n) do
    Busy.Cache.get(rem(n, 20_000) + 1)
    GenServer.cast(Busy.Hoarder, {:keep, :binary.copy(<<n::32>>, 64)})

    1..3
    |> Enum.map(fn part -> Task.async(fn -> work(n, part) end) end)
    |> Task.await_many()

    case rem(n, 97) do
      0 -> raise "request #{n} could not be answered"
      13 -> exit({:timeout, {Busy.Cache, :get, [n]}})
      _ -> :ok
    end
  end

  defp work(n, part) do
    Enum.reduce(1..(1_000 * part), n, fn i, sum -> rem(sum * 31 + i, 1_000_003) end)
  end
end

defmodule Busy.Traffic do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)

  @impl true
  def init(n) do
    Process.send_after(self(), :more, 100)
    {:ok, n}
  end

  @impl true
  def handle_info(:more, n) do
    for i <- 1..5 do
      Task.Supervisor.start_child(Busy.Requests, Busy.Request, :handle, [n + i])
    end

    Process.send_after(self(), :more, 100)
    {:noreply, n + 5}
  end
end

defmodule Busy.App do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [
        Busy.Cache,
        Busy.Hoarder,
        {Task.Supervisor, name: Busy.Requests},
        Busy.Traffic
      ],
      strategy: :one_for_one,
      name: Busy.Supervisor
    )
  end
end

Logger.configure(level: :emergency)

# As an application, so that its processes are accounted to one.
:ok =
  :application.load(
    {:application, :busy,
     description: ~c"A node with something going on in it",
     vsn: ~c"1",
     modules: [],
     registered: [],
     applications: [:kernel, :stdlib, :elixir],
     mod: {Busy.App, []}}
  )

{:ok, _} = Application.ensure_all_started(:busy)

IO.puts("#{node()} is busy. Stop it with Ctrl-C.")
Process.sleep(:infinity)
