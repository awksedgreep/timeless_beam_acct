# What a collector's samples, records, and spans cost to store.
#
#     TIMELESS_TEST_METRICS_URL=http://127.0.0.1:28428 \
#     TIMELESS_TEST_LOGS_URL=http://127.0.0.1:29428 \
#     TIMELESS_TEST_TRACES_URL=http://127.0.0.1:30428 \
#       mix run bench/compression.exs [minutes]
#
# The node of bench/varied_node.exs, with a collector in it at the
# intervals a collector keeps unless told, writing to planes that were
# started for it, for an hour unless told otherwise. What it sent is
# counted as it is sent. What the planes made of it is read from them
# afterwards, by bench/compression_report.py.
#
# The planes are those of `mix test --only planes`: their own ports, and
# databases that are thrown away.

defmodule Bench.Compression do
  @moduledoc false
  @behaviour TimelessBeamAcct.Sink

  alias TimelessBeamAcct.{Encode, Sink}

  @impl true
  def init(opts) do
    with {:ok, http} <- Sink.Http.init(Keyword.delete(opts, :counts)) do
      {:ok, %{http: http, counts: Keyword.fetch!(opts, :counts)}}
    end
  end

  # What is sent is counted, and then sent as it would have been.
  @impl true
  def write(state, host, node, tick) do
    count(state.counts, 1, tick.metrics.count)
    count(state.counts, 2, IO.iodata_length(Encode.prometheus_text(host, node, tick.metrics)))
    count(state.counts, 3, length(tick.events))
    count(state.counts, 4, IO.iodata_length(Encode.ndjson(host, node, tick.events)))
    count(state.counts, 5, length(tick.spans))
    count(state.counts, 6, IO.iodata_length(Encode.otlp_json(host, node, tick.spans)))
    count(state.counts, 7, 1)

    case Sink.Http.write(state.http, host, node, tick) do
      {:ok, http} -> {:ok, %{state | http: http}}
      {:error, reason, http} -> {:error, reason, %{state | http: http}}
    end
  end

  @impl true
  def flush(state) do
    case Sink.Http.flush(state.http) do
      {:ok, http} -> {:ok, %{state | http: http}}
      {:error, reason, http} -> {:error, reason, %{state | http: http}}
    end
  end

  @impl true
  def close(_state), do: :ok

  @impl true
  def describe(state), do: "counted, and " <> Sink.Http.describe(state.http)

  defp count(counts, at, by), do: :counters.add(counts, at, by)
end

urls =
  for {key, variable, not_on} <- [
        {:metrics_url, "TIMELESS_TEST_METRICS_URL", 8428},
        {:logs_url, "TIMELESS_TEST_LOGS_URL", 9428},
        {:traces_url, "TIMELESS_TEST_TRACES_URL", 10428}
      ] do
    url = System.get_env(variable) || raise "#{variable} is not set: where are the planes?"

    if URI.parse(url).port == not_on,
      do: raise("#{variable} is #{url}: that is where the planes of this machine are")

    {key, url}
  end

minutes =
  case System.argv() do
    [minutes | _] -> String.to_integer(minutes)
    [] -> 60
  end

System.put_env("VARIED_ALONE", "0")
Code.require_file("varied_node.exs", __DIR__)
Varied.Apps.start(seed: 1)
Process.sleep(2_000)

counts = :counters.new(7, [])
{:ok, _} = TimelessBeamAcct.start_link(sink: {Bench.Compression, [counts: counts] ++ urls})

IO.puts(
  "collecting for #{minutes} minutes, from #{TimelessBeamAcct.Clock.format(TimelessBeamAcct.Clock.now())}"
)

for minute <- 1..minutes do
  Process.sleep(60_000)

  if rem(minute, 5) == 0 do
    status = TimelessBeamAcct.status()

    IO.puts(
      "#{minute}m: #{:counters.get(counts, 7)} ticks, #{:counters.get(counts, 1)} samples, " <>
        "#{:counters.get(counts, 3)} records, #{:counters.get(counts, 5)} spans; " <>
        "#{status.sweep.processes} processes, #{status.sweep.reported} with series; " <>
        "writer failed #{status.writer.failed}, let go #{status.dropped.records} records"
    )
  end
end

:ok = TimelessBeamAcct.flush()
status = TimelessBeamAcct.status()
TimelessBeamAcct.stop()

sent = %{
  minutes: minutes,
  ticks: :counters.get(counts, 7),
  samples: :counters.get(counts, 1),
  samples_bytes: :counters.get(counts, 2),
  records: :counters.get(counts, 3),
  records_bytes: :counters.get(counts, 4),
  spans: :counters.get(counts, 5),
  spans_bytes: :counters.get(counts, 6),
  processes: status.sweep.processes,
  with_series: status.sweep.reported,
  failed_writes: status.writer.failed,
  records_let_go: status.dropped.records,
  started: status.tracer && status.tracer.spawns,
  ended: status.tracer && status.tracer.exits
}

out = System.get_env("COMPRESSION_SENT", "compression_sent.json")
File.write!(out, JSON.encode!(sent))
IO.puts("what was sent is in #{out}")
IO.inspect(sent, label: "sent")
System.halt(0)
