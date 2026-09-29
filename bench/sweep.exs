# What a sweep costs, by how many processes there are.
#
#     mix run bench/sweep.exs
#
# Processes are made that do nothing, swept a few times, and ended.

alias TimelessBeamAcct.{Batch, Options, Processes}

defmodule Bench.Sweep do
  def idle, do: receive(do: (:stop -> :ok))

  def run(count) do
    pids = for _ <- 1..count, do: spawn(__MODULE__, :idle, [])
    name = :"bench_sweep_#{count}"
    owner = self()

    # In a process of its own, as the collector is: its heap is what the
    # sweep costs in memory, beside the table.
    {pid, ref} =
      spawn_monitor(fn ->
        state = Processes.new(Options.new!(name: name, sink: :stdout))

        {first, state} = sweep(state)
        {times, _state} = Enum.map_reduce(1..5, state, fn _, state -> sweep(state) end)
        {:memory, heap} = Process.info(self(), :memory)

        send(owner, %{
          first: first,
          later: Enum.min(times),
          table: :ets.info(state.table, :memory) * :erlang.system_info(:wordsize),
          heap: heap
        })
      end)

    result =
      receive do
        %{} = result -> result
        {:DOWN, ^ref, _, ^pid, reason} -> exit(reason)
      end

    Enum.each(pids, &send(&1, :stop))
    result
  end

  defp sweep(state) do
    {us, {state, _batch, _gone, _found}} =
      :timer.tc(fn -> Processes.sweep(state, Batch.new(0)) end)

    {us, state}
  end
end

limit = :erlang.system_info(:process_limit)
IO.puts("OTP #{System.otp_release()}, #{System.schedulers_online()} schedulers, at most #{limit} processes\n")
IO.puts("  processes   first sweep   later sweeps   a process     table    collector's heap")

for count <- [1_000, 10_000, 100_000, 500_000], count < limit - 1_000 do
  %{first: first, later: later, table: table, heap: heap} = Bench.Sweep.run(count)

  IO.puts(
    [
      String.pad_leading("#{count}", 11),
      String.pad_leading("#{Float.round(first / 1000, 1)} ms", 14),
      String.pad_leading("#{Float.round(later / 1000, 1)} ms", 15),
      String.pad_leading("#{round(later * 1000 / count)} ns", 12),
      String.pad_leading(TimelessBeamAcct.Human.bytes(table), 10),
      String.pad_leading(TimelessBeamAcct.Human.bytes(heap), 20)
    ]
  )

  # Let the last lot end before the next is made.
  Process.sleep(500)
end
