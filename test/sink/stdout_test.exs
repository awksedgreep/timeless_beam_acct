defmodule TimelessBeamAcct.Sink.StdoutTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias TimelessBeamAcct.{Batch, Encode, Event, Span, Tick}
  alias TimelessBeamAcct.Sink.Stdout

  defp tick do
    %Tick{
      metrics: Batch.push(Batch.new(1_753_000_000), "vm_run_queue", [{"scheduler", "1"}], 2),
      events: [
        %Event{ts_us: 1_753_000_000_000_001, level: :error, message: "é crashed", fields: %{}}
      ],
      spans: [
        %Span{
          trace_id: <<1::128>>,
          span_id: <<2::64>>,
          name: "Shop.Worker",
          service: "shop",
          start_ns: 1_753_000_000_000_000_000,
          duration_ns: 5
        }
      ]
    }
  end

  defp device do
    {:ok, device} = StringIO.open("")
    device
  end

  defp printed(device) do
    {_input, output} = StringIO.contents(device)
    output
  end

  test "what is printed is what would be sent: samples, then records, then spans" do
    device = device()
    {:ok, sink} = Stdout.init(device: device)

    assert {:ok, ^sink} = Stdout.write(sink, "ohm", "app@ohm", tick())

    assert [samples, record, spans] = String.split(printed(device), "\n", trim: true)
    assert samples == ~s(vm_run_queue{host="ohm",node="app@ohm",scheduler="1"} 2 1753000000000)
    assert JSON.decode!(record)["_msg"] == "é crashed"
    assert %{"resourceSpans" => [_]} = JSON.decode!(spans)

    assert printed(device) ==
             IO.iodata_to_binary([
               Encode.prometheus_text("ohm", "app@ohm", tick().metrics),
               Encode.ndjson("ohm", "app@ohm", tick().events),
               Encode.otlp_json("ohm", "app@ohm", tick().spans),
               "\n"
             ])
  end

  test "a tick with no spans prints no line for them" do
    device = device()
    {:ok, sink} = Stdout.init(device: device)

    assert {:ok, _} = Stdout.write(sink, "h", "n", %{tick() | spans: []})
    assert [_samples, _record] = String.split(printed(device), "\n", trim: true)
  end

  test "an empty tick prints nothing" do
    device = device()
    {:ok, sink} = Stdout.init(device: device)

    assert {:ok, _} = Stdout.write(sink, "h", "n", %Tick{metrics: Batch.new(1)})
    assert printed(device) == ""
  end

  test "with no device given it prints to standard output" do
    {:ok, sink} = Stdout.init([])

    output =
      capture_io(fn ->
        assert {:ok, _} = Stdout.write(sink, "h", "n", %{tick() | events: [], spans: []})
      end)

    assert output == ~s(vm_run_queue{host="h",node="n",scheduler="1"} 2 1753000000000\n)
    assert Stdout.describe(sink) == "stdout"
  end

  test "a device that has gone is an error, and is not raised" do
    device = device()
    {:ok, sink} = Stdout.init(device: device)
    {:ok, _} = StringIO.close(device)

    assert {:error, _reason, ^sink} = Stdout.write(sink, "h", "n", tick())
  end

  test "an option it does not have is refused" do
    assert {:error, why} = Stdout.init(colour: true)
    assert why =~ ":colour"
    assert {:error, _} = Stdout.init(device: "a file")
  end
end
