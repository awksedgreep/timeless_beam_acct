# What it costs a node to be listened to, when it starts processes as fast
# as it can.
#
#     mix run bench/spawns.exs
#
# Processes are started that end at once, in lots, by as many processes as
# there are schedulers. How many a second are started is measured with no
# collector, and with one listening.

alias TimelessBeamAcct.{Options, Processes, Tracer}

defmodule Bench.Spawns do
  def storm(total) do
    workers = System.schedulers_online()
    each = div(total, workers)

    {us, :ok} =
      :timer.tc(fn ->
        1..workers
        |> Enum.map(fn _ -> Task.async(fn -> spawn_many(each) end) end)
        |> Task.await_many(:infinity)

        :ok
      end)

    {each * workers, us}
  end

  defp spawn_many(0), do: :ok

  defp spawn_many(n) do
    {_pid, ref} = spawn_monitor(fn -> :ok end)

    receive do
      {:DOWN, ^ref, _, _, _} -> spawn_many(n - 1)
    end
  end

  def rate({count, us}), do: round(count / us * 1_000_000)
end

total = 400_000
# Once, for whatever has to be loaded.
Bench.Spawns.storm(20_000)

without = Enum.max(for _ <- 1..3, do: Bench.Spawns.rate(Bench.Spawns.storm(total)))

for descriptions <- [false, true] do
  options =
    Options.new!(
      name: :"bench_spawns_#{descriptions}",
      sink: :stdout,
      anomalies: false,
      descriptions: descriptions
    )

  {:ok, tracer} = Tracer.start_link(options)
  handle = Tracer.handle(options)
  processes = Processes.new(options)

  # The collector's part: what was heard is taken in once a second, as it
  # would be at each tick were ticks a second apart.
  taker =
    spawn_link(fn ->
      Stream.repeatedly(fn ->
        Process.sleep(1000)
        Tracer.take(handle)
      end)
      |> Stream.run()
    end)

  rates =
    for _ <- 1..3 do
      rate = Bench.Spawns.rate(Bench.Spawns.storm(total))
      Process.sleep(1500)
      rate
    end

  counts = Tracer.counts(handle)
  {:memory, memory} = Process.info(tracer, :memory)
  Process.unlink(taker)
  Process.exit(taker, :kill)

  IO.puts("""
  listening#{if descriptions, do: ", and to what each process says it is", else: ""}:
    #{Enum.max(rates)} processes a second, against #{without} with no one listening
    (#{Float.round(100 - 100 * Enum.max(rates) / without, 1)}% fewer)
    the tracer heard of #{counts.spawns} starting and #{counts.exits} ending
    and stopped listening #{counts.suspensions} times
    its memory at the end: #{TimelessBeamAcct.Human.bytes(memory)}
  """)

  GenServer.stop(tracer)
  :ets.delete(processes.table)
end
