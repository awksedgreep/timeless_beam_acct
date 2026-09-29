# How many processes a second a node can start and be heard in full.
#
#     mix run bench/heard.exs
#
# Processes that end at once are started at a steady rate, for a few
# seconds at each rate, with a tracer listening and what it hears taken
# from it once a second. A rate is heard in full if the tracer never had
# to stop listening.

alias TimelessBeamAcct.{Options, Tracer}

defmodule Bench.Heard do
  # `rate` processes a second for `seconds`, in lots a hundredth of a
  # second apart.
  def steady(rate, seconds) do
    lot = max(div(rate, 100), 1)
    started = System.monotonic_time(:millisecond)

    for n <- 1..(seconds * 100) do
      for _ <- 1..lot, do: spawn(fn -> :ok end)
      wait = started + n * 10 - System.monotonic_time(:millisecond)
      if wait > 0, do: Process.sleep(wait)
    end

    took = System.monotonic_time(:millisecond) - started
    round(lot * seconds * 100 / took * 1000)
  end
end

IO.puts("   asked for     started    heard of   stopped listening   most waiting   the tracer's share of a scheduler")

for rate <- [1_000, 10_000, 50_000, 100_000, 200_000] do
  options = Options.new!(name: :"bench_heard_#{rate}", sink: :stdout, anomalies: false)
  {:ok, tracer} = Tracer.start_link(options)
  handle = Tracer.handle(options)
  test = self()

  watcher =
    spawn_link(fn ->
      Stream.iterate(0, fn most ->
        receive do
          {:most, from} -> send(from, {:most, most})
        after
          100 -> :ok
        end

        if rem(System.monotonic_time(:millisecond), 1000) < 100, do: Tracer.take(handle)
        {:message_queue_len, waiting} = Process.info(tracer, :message_queue_len)
        max(most, waiting)
      end)
      |> Stream.run()
    end)

  {:reductions, before} = Process.info(tracer, :reductions)
  began = System.monotonic_time(:millisecond)
  actual = Bench.Heard.steady(rate, 5)
  Process.sleep(300)
  took = System.monotonic_time(:millisecond) - began
  {:reductions, reductions} = Process.info(tracer, :reductions)
  counts = Tracer.counts(handle)

  send(watcher, {:most, test})
  most = receive(do: ({:most, most} -> most))

  # A scheduler does about a hundred million reductions a second when it
  # does nothing else.
  share = (reductions - before) / (took / 1000) / 100_000_000 * 100

  IO.puts([
    String.pad_leading("#{rate}/s", 12),
    String.pad_leading("#{actual}/s", 12),
    String.pad_leading("#{round(counts.exits / (took / 1000))}/s", 12),
    String.pad_leading("#{counts.suspensions} times", 20),
    String.pad_leading("#{most}", 15),
    String.pad_leading("#{Float.round(share, 1)}%", 12)
  ])

  Process.unlink(watcher)
  Process.exit(watcher, :kill)
  GenServer.stop(tracer)
  Process.sleep(500)
end
