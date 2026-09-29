# What a tick costs, by how many processes ended in it.
#
#     mix run bench/tick.exs
#
# A collector is run with a sink that encodes what it is given as the
# planes are sent it, and sends it nowhere.

defmodule Bench.Encoded do
  @behaviour TimelessBeamAcct.Sink
  alias TimelessBeamAcct.Encode

  def init(opts), do: {:ok, Keyword.fetch!(opts, :to)}

  def write(to, host, node, tick) do
    {us, bytes} =
      :timer.tc(fn ->
        IO.iodata_length(Encode.prometheus_text(host, node, tick.metrics)) +
          IO.iodata_length(Encode.ndjson(host, node, tick.events)) +
          IO.iodata_length(Encode.otlp_json(host, node, tick.spans))
      end)

    send(to, {:encoded, tick.metrics.count, length(tick.events), length(tick.spans), bytes, us})
    {:ok, to}
  end

  def describe(_), do: "encoded, and sent nowhere"
end

defmodule Bench.Tick do
  def ended(count) do
    1..count//1
    |> Enum.map(fn _ -> spawn_monitor(fn -> :ok end) end)
    |> Enum.each(fn {_pid, ref} ->
      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      end
    end)
  end

  def reading(name) do
    {us, :ok} = :timer.tc(fn -> TimelessBeamAcct.tick(name) end)

    receive do
      {:encoded, samples, records, spans, bytes, encoding} ->
        %{us: us, samples: samples, records: records, spans: spans, bytes: bytes, encoding: encoding}
    after
      5_000 -> raise "nothing was written"
    end
  end
end

for {max_records, said} <- [{5_000, "at most 5000 records a tick, which is what a collector keeps unless told"}, {1_000_000, "a record of every one"}] do
  name = :"bench_tick_#{max_records}"

  {:ok, _} =
    TimelessBeamAcct.start_link(
      name: name,
      sink: {Bench.Encoded, to: self()},
      interval: 3600,
      process_interval: 3600,
      max_records: max_records,
      trace_max_queue: 10_000_000,
      history: 0
    )

  Bench.Tick.reading(name)
  Bench.Tick.reading(name)

  IO.puts("\n#{said}\n")
  IO.puts("  ended   the tick   a process   encoding    samples   records     spans    on the wire")

  for count <- [0, 1_000, 10_000, 100_000] do
    Bench.Tick.ended(count)
    # For word of the last of them to arrive.
    Process.sleep(1000)
    reading = Bench.Tick.reading(name)

    IO.puts([
      String.pad_leading("#{count}", 7),
      String.pad_leading("#{Float.round(reading.us / 1000, 1)} ms", 11),
      String.pad_leading(if(count > 0, do: "#{round(reading.us * 1000 / count)} ns", else: "-"), 12),
      String.pad_leading("#{Float.round(reading.encoding / 1000, 1)} ms", 11),
      String.pad_leading("#{reading.samples}", 11),
      String.pad_leading("#{reading.records}", 10),
      String.pad_leading("#{reading.spans}", 10),
      String.pad_leading(TimelessBeamAcct.Human.bytes(reading.bytes), 15)
    ])
  end

  TimelessBeamAcct.stop(name)
end
