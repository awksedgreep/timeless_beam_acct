# A node with many kinds of thing going on in it, for measuring what a
# collector's records cost to store.
#
# examples/busy_node.exs does one thing over and over, and what is all
# alike compresses better than what a node does. This has a dozen kinds
# of request that take different times and end in different ways, pools
# of workers under names, connections that come and go, and tables that
# grow.
#
# It is given a seed, and does the same each time it is given the same
# one. It is required by bench/compression.exs, and can be run by itself:
#
#     elixir --sname varied --cookie varied bench/varied_node.exs

defmodule Varied do
  @moduledoc false

  @kinds [
    # {module, function, share, children, milliseconds at most}
    {Shop.Orders, :create, 18, 3, 40},
    {Shop.Orders, :show, 30, 1, 8},
    {Shop.Orders, :cancel, 3, 2, 25},
    {Shop.Catalog, :search, 22, 4, 120},
    {Shop.Catalog, :item, 35, 0, 4},
    {Shop.Cart, :add, 20, 1, 10},
    {Shop.Cart, :checkout, 6, 5, 400},
    {Shop.Accounts, :sign_in, 8, 2, 90},
    {Shop.Accounts, :profile, 12, 1, 12},
    {Mailer.Delivery, :send, 5, 1, 900},
    {Mailer.Digest, :build, 1, 4, 30_000},
    {Reports.Monthly, :run, 1, 5, 90_000}
  ]

  def kinds, do: @kinds

  def pick(kinds \\ @kinds) do
    total = kinds |> Enum.map(&elem(&1, 2)) |> Enum.sum()
    at = :rand.uniform(total)

    Enum.reduce_while(kinds, at, fn {_, _, share, _, _} = kind, left ->
      if left <= share, do: {:halt, kind}, else: {:cont, left - share}
    end)
  end

  # Most of what a node does takes a little of the time it may, and some
  # of it takes all of it.
  def some_of(most), do: max(round(most * :math.pow(:rand.uniform(), 3)), 0)

  def work(milliseconds) do
    until = System.monotonic_time(:millisecond) + milliseconds
    spin(until, 0)
  end

  defp spin(until, n) do
    if System.monotonic_time(:millisecond) >= until do
      n
    else
      Process.sleep(min(5, max(until - System.monotonic_time(:millisecond), 0)))
      spin(until, Enum.reduce(1..200, n, &rem(&1 * 31 + &2, 1_000_003)))
    end
  end

  def outcome(n) do
    case :rand.uniform(1000) do
      r when r <= 940 ->
        :ok

      r when r <= 952 ->
        raise "request #{n} could not be answered"

      r when r <= 960 ->
        raise ArgumentError, "order #{rem(n, 977)} has no such item"

      r when r <= 966 ->
        raise KeyError, key: :customer, term: %{order: n}

      r when r <= 978 ->
        exit({:timeout, {GenServer, :call, [Shop.Inventory, {:reserve, n}, 5000]}})

      r when r <= 984 ->
        exit({:noproc, {GenServer, :call, [Shop.Payments, :charge, 5000]}})

      r when r <= 990 ->
        exit({:shutdown, :client_closed})

      r when r <= 996 ->
        exit(:overloaded)

      _ ->
        Process.exit(self(), :kill)
    end
  end
end

for {module, function, _share, children, most} <- Varied.kinds() do
  unless Code.ensure_loaded?(module) do
    Module.create(module, quote(do: @moduledoc(false)), Macro.Env.location(__ENV__))
  end

  :code.purge(module)
  :code.delete(module)

  same = for {^module, f, _, c, m} <- Varied.kinds(), do: {f, c, m}

  Module.create(
    module,
    for {f, c, m} <- same do
      quote do
        def unquote(f)(n) do
          held = :binary.copy(<<n::32>>, :rand.uniform(4000))

          1..max(unquote(c), 1)
          |> Enum.take(unquote(c))
          |> Enum.map(fn _part ->
            Task.async(fn -> Varied.work(Varied.some_of(div(unquote(m), 2))) end)
          end)
          |> Task.await_many(:infinity)

          Varied.work(Varied.some_of(unquote(m)))
          Varied.outcome(n)
          byte_size(held)
        end
      end
    end,
    Macro.Env.location(__ENV__)
  )

  _ = {function, children, most}
end

defmodule Shop.Pool.Worker do
  @moduledoc false
  use GenServer

  def start_link(n), do: GenServer.start_link(__MODULE__, n, name: :"shop_pool_worker_#{n}")

  @impl true
  def init(n) do
    :rand.seed(:exsss, {n, 17, 4})
    Process.send_after(self(), :work, :rand.uniform(2000))
    {:ok, []}
  end

  @impl true
  def handle_info(:work, held) do
    Varied.work(Varied.some_of(30))
    held = [:binary.copy(<<0>>, :rand.uniform(20_000)) | held]
    # What it holds grows, and is let go of all at once.
    held = if length(held) > 40 + :rand.uniform(40), do: [], else: held
    Process.send_after(self(), :work, 200 + :rand.uniform(3000))
    {:noreply, held}
  end
end

defmodule Shop.Connection do
  @moduledoc false

  def start(supervisor, n) do
    Task.Supervisor.start_child(supervisor, __MODULE__, :serve, [n])
  end

  # Half a minute to twenty minutes, most of them short.
  def serve(n) do
    :rand.seed(:exsss, {n, 3, 11})
    lives = 30_000 + Varied.some_of(1_170_000)
    until = System.monotonic_time(:millisecond) + lives
    loop(until, [])
  end

  defp loop(until, held) do
    if System.monotonic_time(:millisecond) >= until do
      if :rand.uniform(10) == 1, do: exit({:shutdown, :closed}), else: :ok
    else
      Process.sleep(500 + :rand.uniform(4000))
      Varied.work(Varied.some_of(5))
      held = Enum.take([:binary.copy(<<1>>, :rand.uniform(8000)) | held], 12)
      loop(until, held)
    end
  end
end

defmodule Shop.Traffic do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    :rand.seed(:exsss, {Keyword.get(opts, :seed, 1), 5, 9})
    :ets.new(:shop_sessions, [:named_table, :set, :public])
    :ets.new(:shop_cache, [:named_table, :set, :public])

    for n <- 1..Keyword.get(opts, :connections, 300),
        do: Shop.Connection.start(Shop.Connections, n)

    Process.send_after(self(), :more, 100)
    {:ok, %{n: 0, a_second: Keyword.get(opts, :requests, 25), connections: 300}}
  end

  @impl true
  def handle_info(:more, state) do
    # So many a second, more at some times than at others.
    now = div(System.monotonic_time(:second), 60)
    swell = 1.0 + 0.6 * :math.sin(now / 3)
    count = round(state.a_second / 10 * swell * (0.5 + :rand.uniform()))

    n =
      Enum.reduce(1..max(count, 1)//1, state.n, fn _, n ->
        {module, function, _, _, _} = Varied.pick()

        supervisor =
          if module in [Mailer.Delivery, Mailer.Digest], do: Mailer.Jobs, else: Shop.Requests

        Task.Supervisor.start_child(supervisor, module, function, [n + 1])
        :ets.insert(:shop_sessions, {rem(n, 5000), n, :binary.copy(<<2>>, 64)})
        if rem(n, 7) == 0, do: :ets.insert(:shop_cache, {n, :binary.copy(<<3>>, 256)})
        n + 1
      end)

    if rem(n, 5000) < count, do: :ets.delete_all_objects(:shop_cache)

    # A connection that has gone is replaced, give or take.
    alive = Task.Supervisor.children(Shop.Connections) |> length()

    connections =
      Enum.reduce(
        1..max(state.connections - alive + :rand.uniform(3) - 2, 0)//1,
        state.connections,
        fn _, c ->
          Shop.Connection.start(Shop.Connections, c + 1000)
          c
        end
      )

    Process.send_after(self(), :more, 100)
    {:noreply, %{state | n: n, connections: connections}}
  end
end

defmodule Varied.Apps do
  @moduledoc false

  defmodule Shop do
    use Application

    def start(_type, _args) do
      children =
        [
          {Task.Supervisor, name: Elixir.Shop.Requests},
          {Task.Supervisor, name: Elixir.Shop.Connections}
        ] ++
          for(
            n <- 1..40,
            do: Supervisor.child_spec({Elixir.Shop.Pool.Worker, n}, id: {:worker, n})
          ) ++
          [{Elixir.Shop.Traffic, Application.get_env(:shop, :traffic, [])}]

      Supervisor.start_link(children, strategy: :one_for_one, name: Elixir.Shop.Supervisor)
    end
  end

  defmodule Mailer do
    use Application

    def start(_type, _args) do
      Supervisor.start_link([{Task.Supervisor, name: Elixir.Mailer.Jobs}],
        strategy: :one_for_one,
        name: Elixir.Mailer.Supervisor
      )
    end
  end

  def start(opts \\ []) do
    Logger.configure(level: :emergency)

    for {app, module, said} <- [
          {:mailer, Mailer, ~c"What is sent"},
          {:shop, Shop, ~c"What is sold"}
        ] do
      :ok =
        :application.load(
          {:application, app,
           description: said,
           vsn: ~c"1",
           modules: [],
           registered: [],
           applications: [:kernel, :stdlib, :elixir],
           mod: {module, []}}
        )
    end

    Application.put_env(:shop, :traffic, opts)
    {:ok, _} = Application.ensure_all_started(:mailer)
    {:ok, _} = Application.ensure_all_started(:shop)
    :ok
  end
end

if System.get_env("VARIED_ALONE", "1") == "1" and not Code.ensure_loaded?(Bench.Compression) do
  Varied.Apps.start()
  IO.puts("#{node()} has a dozen things going on. Stop it with Ctrl-C.")
  Process.sleep(:infinity)
end
