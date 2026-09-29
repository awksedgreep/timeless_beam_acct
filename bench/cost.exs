# What a collector costs a node that has something going on in it.
#
#     mix run bench/cost.exs
#
# The node of examples/busy_node.exs, with a collector in it at the
# intervals a collector keeps unless told, for a minute. What the
# collector's processes did is set against what the node did.

defmodule Bench.Counted do
  @behaviour TimelessBeamAcct.Sink
  alias TimelessBeamAcct.{Batch, Encode}

  def init(opts), do: {:ok, Keyword.fetch!(opts, :to)}

  def write(to, host, node, tick) do
    tiers =
      tick.metrics
      |> Batch.samples()
      |> Enum.frequencies_by(fn {name, _, _} ->
        name |> String.split("_") |> Enum.take(2) |> Enum.join("_")
      end)

    send(to, {
      :written,
      tiers,
      length(tick.events),
      length(tick.spans),
      IO.iodata_length(Encode.prometheus_text(host, node, tick.metrics)),
      IO.iodata_length(Encode.ndjson(host, node, tick.events)),
      IO.iodata_length(Encode.otlp_json(host, node, tick.spans))
    })

    {:ok, to}
  end

  def describe(_), do: "counted, and sent nowhere"
end

spawn(fn -> Code.require_file("examples/busy_node.exs") end)
Process.sleep(2_000)

seconds = 60

{:ok, _} = TimelessBeamAcct.start_link(sink: {Bench.Counted, to: self()})

# Those of them there are: on a VM without trace sessions there is no
# tracer, and the collector runs without one.
parts =
  for {name, said} <- [Collector: "the loop", Tracer: "the tracer", Writer: "the writer"],
      Process.whereis(Module.concat(TimelessBeamAcct, name)),
      do: {name, said}

reductions = fn name ->
  {:reductions, r} = Process.info(Process.whereis(Module.concat(TimelessBeamAcct, name)), :reductions)
  r
end

# From the first tick that has samples, which is the first on a round time.
receive do
  {:written, tiers, _, _, _, _, _} when map_size(tiers) > 0 -> :ok
end

before = Map.new(parts, fn {name, _} -> {name, reductions.(name)} end)
{node_before, _} = :erlang.statistics(:reductions)
{runtime_before, _} = :erlang.statistics(:runtime)
began = System.monotonic_time(:millisecond)
Process.sleep(seconds * 1000)
took = (System.monotonic_time(:millisecond) - began) / 1000
{node_after, _} = :erlang.statistics(:reductions)
{runtime_after, _} = :erlang.statistics(:runtime)

collect = fn collect, acc ->
  receive do
    {:written, _, _, _, _, _, _} = tick -> collect.(collect, [tick | acc])
  after
    0 -> Enum.reverse(acc)
  end
end

ticks = collect.(collect, [])
status = TimelessBeamAcct.status()
counts = status.tracer

starting =
  if counts,
    do: "starting #{round(counts.spawns / (took + 10))} processes a second",
    else: "on OTP #{System.otp_release()}, which does not say how many it starts: word of each exit is #{status.exits}"

IO.puts("""

#{length(ticks)} ticks in #{Float.round(took, 1)}s of a node with #{status.sweep.processes} processes, \
#{status.sweep.reported} of them with series of their own,
#{starting}

what the node did           #{TimelessBeamAcct.Human.count((node_after - node_before) / took)} reductions a second, \
#{Float.round((runtime_after - runtime_before) / 10 / took, 1)}% of one CPU
""")

total =
  for {name, said} <- parts, reduce: 0 do
    total ->
      did = (reductions.(name) - before[name]) / took
      {:memory, memory} = Process.info(Process.whereis(Module.concat(TimelessBeamAcct, name)), :memory)

      IO.puts(
        String.pad_trailing(said, 28) <>
          String.pad_trailing("#{TimelessBeamAcct.Human.count(did)} reductions a second", 32) <>
          "#{Float.round(100 * did / ((node_after - node_before) / took), 1)}% of the node's" <>
          "    #{TimelessBeamAcct.Human.bytes(memory)}"
      )

      total + did
  end

IO.puts(
  String.pad_trailing("the collector, in all", 28) <>
    String.pad_trailing("#{TimelessBeamAcct.Human.count(total)} reductions a second", 32) <>
    "#{Float.round(100 * total / ((node_after - node_before) / took), 1)}% of the node's"
)

tables =
  for table <- [TimelessBeamAcct.Processes, TimelessBeamAcct.Records, TimelessBeamAcct.Spans],
      do: :ets.info(table, :memory) * :erlang.system_info(:wordsize)

IO.puts("""
a sweep                     #{TimelessBeamAcct.Human.duration(status.sweep.seconds)}
the table of processes      #{TimelessBeamAcct.Human.bytes(Enum.at(tables, 0))}
the records and spans kept  #{TimelessBeamAcct.Human.bytes(Enum.at(tables, 1) + Enum.at(tables, 2))}
""")

{tiers, records, spans, text, lines, otlp} =
  Enum.reduce(ticks, {%{}, 0, 0, 0, 0, 0}, fn {:written, tiers, records, spans, text, lines, otlp},
                                              {t, r, s, a, b, c} ->
    {Map.merge(t, tiers, fn _, x, y -> x + y end), r + records, s + spans, a + text, b + lines,
     c + otlp}
  end)

n = length(ticks)
IO.puts("a tick, on average:")

for {tier, count} <- Enum.sort(tiers) do
  IO.puts("  #{String.pad_trailing(tier <> "_*", 26)}#{round(count / n)} samples")
end

IO.puts("""
  #{String.pad_trailing("samples, in all", 26)}#{round(Enum.sum(Map.values(tiers)) / n)}, #{TimelessBeamAcct.Human.bytes(text / n)} on the wire
  #{String.pad_trailing("records", 26)}#{round(records / n)}, #{TimelessBeamAcct.Human.bytes(lines / n)} on the wire, #{if records > 0, do: round(lines / records), else: 0} bytes each
  #{String.pad_trailing("spans", 26)}#{round(spans / n)}, #{TimelessBeamAcct.Human.bytes(otlp / n)} on the wire, #{if spans > 0, do: round(otlp / spans), else: 0} bytes each
""")

System.halt(0)
