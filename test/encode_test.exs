defmodule TimelessBeamAcct.EncodeTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.{Batch, Encode, Event, Span}

  defp text(host \\ "ohm", node \\ "app@ohm", batch) do
    host |> Encode.prometheus_text(node, batch) |> IO.iodata_to_binary()
  end

  # A batch with a value in it as it is, and not as `Batch.push/4` would
  # have rounded it.
  defp batch_of(value), do: %Batch{ts: 1, samples: [{"m", [], value}], count: 1}

  defp written(value) do
    [_name, field, _ts] =
      value |> batch_of() |> text() |> String.trim_trailing() |> String.split(" ")

    field
  end

  describe "samples" do
    test "text carries host, node, labels, and a timestamp in milliseconds" do
      batch =
        Batch.new(1_753_000_000)
        |> Batch.push("vm_run_queue", 0.5)
        |> Batch.push("proc_memory_bytes", [{"pid", "0.42.0"}, {"name", "a\"b\\c"}], 12.0)

      assert text(batch) ==
               ~S|vm_run_queue{host="ohm",node="app@ohm"} 0.5 1753000000000| <>
                 "\n" <>
                 ~S|proc_memory_bytes{host="ohm",node="app@ohm",pid="0.42.0",name="a\"b\\c"} 12 1753000000000| <>
                 "\n"
    end

    test "samples are written in the order they were added, and labels in the order given" do
      batch =
        Batch.new(1)
        |> Batch.push("first", [{"z", "1"}, {"a", "2"}], 1)
        |> Batch.push("second", 2)
        |> Batch.push("third", 3)

      assert text("h", "n", batch) ==
               """
               first{host="h",node="n",z="1",a="2"} 1 1000
               second{host="h",node="n"} 2 1000
               third{host="h",node="n"} 3 1000
               """
    end

    test "a line ending in a label is written as two characters" do
      batch = Batch.push(Batch.new(1), "m", [{"reason", "one\ntwo"}], 1)
      assert text("h", "n", batch) == ~S|m{host="h",node="n",reason="one\ntwo"} 1 1000| <> "\n"
    end

    test "the host and the node are escaped as any label is" do
      batch = Batch.push(Batch.new(1), "m", 1)

      assert text(~S|o"hm|, ~S|app\1@ohm|, batch) ==
               ~S|m{host="o\"hm",node="app\\1@ohm"} 1 1000| <> "\n"
    end

    test "an empty batch is no text" do
      assert text(Batch.new(1)) == ""
    end

    test "an integer is written as an integer" do
      assert written(0) == "0"
      assert written(42) == "42"
      assert written(-7) == "-7"
      assert written(18_446_744_073_709_551_616) == "18446744073709551616"
    end

    test "a whole float is written as an integer" do
      assert written(12.0) == "12"
      assert written(-3.0) == "-3"
      assert written(0.0) == "0"
      assert written(1.0e14) == "100000000000000"
      assert written(999_999_999_999_999.0) == "999999999999999"
    end

    test "a float that is not whole, or is too large to be sure of, is written as a float" do
      assert written(0.5) == "0.5"
      assert written(-0.125) == "-0.125"
      assert written(1.0e15) == "1.0e15"
      assert written(1.0e21) == "1.0e21"
      assert written(1.0e-9) == "1.0e-9"
    end

    test "values round trip through the text" do
      values = [
        0.1 + 0.2,
        1.0e-9,
        123_456_789.123_456_79,
        1.0e21,
        12.0,
        -0.0,
        1.0e15,
        -1.0e15,
        999_999_999_999_999.0,
        4_503_599_627_370_497.0,
        1.7976931348623157e308,
        5.0e-324
      ]

      for value <- values do
        field = written(value)
        assert {parsed, ""} = Float.parse(field), "#{field} is not a number"
        assert <<parsed::float>> == <<value::float>>, "#{inspect(value)} came back as #{field}"
        # What a reader of exposition text accepts: digits, and perhaps a
        # fraction and an exponent.
        assert field =~ ~r/\A-?\d+(\.\d+)?(e[+-]?\d+)?\z/
      end
    end

    test "a sample with no value is not stored" do
      # A float here is always finite: arithmetic that would make one that
      # is not raises. What cannot be measured is nil, and is left out.
      batch =
        Batch.new(1)
        |> Batch.push("m", Batch.rate(1, 2, 10))
        |> Batch.push("m", Batch.pct(1, 0))

      assert Batch.samples(batch) == []
      assert text(batch) == ""
    end
  end

  describe "records" do
    test "ndjson lines carry message, time, level, host, and node" do
      event = %Event{
        ts_us: 1_753_000_000_000_001,
        level: :warning,
        message: "worker <0.7.0> killed",
        fields: %{"application" => "shop", "reductions" => 7, "trapping" => true}
      }

      text = "ohm" |> Encode.ndjson("app@ohm", [event]) |> IO.iodata_to_binary()
      assert String.ends_with?(text, "\n")

      line = JSON.decode!(String.trim_trailing(text))
      assert line["_msg"] == "worker <0.7.0> killed"
      assert line["_time"] == 1_753_000_000_000_001
      assert line["level"] == "warning"
      assert line["host"] == "ohm"
      assert line["node"] == "app@ohm"
      assert line["application"] == "shop"
      assert line["reductions"] == 7
      assert line["trapping"] == true
      assert map_size(line) == 8
    end

    test "there is one line for each record, in order" do
      events =
        for n <- 1..3 do
          %Event{ts_us: n, level: :info, message: "line\n#{n}", fields: %{"n" => n}}
        end

      lines =
        "h"
        |> Encode.ndjson("n", events)
        |> IO.iodata_to_binary()
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)

      assert Enum.map(lines, & &1["_time"]) == [1, 2, 3]
      assert Enum.map(lines, & &1["_msg"]) == ["line\n1", "line\n2", "line\n3"]
      assert IO.iodata_to_binary(Encode.ndjson("h", "n", [])) == ""
    end

    test "the metadata is the fields, the host, and the node" do
      event = %Event{ts_us: 1, level: :error, message: "m", fields: %{"pid" => "<0.7.0>"}}

      assert Encode.event_metadata("ohm", "app@ohm", event) ==
               %{"pid" => "<0.7.0>", "host" => "ohm", "node" => "app@ohm"}
    end

    test "every level is written as its name" do
      for level <- [:info, :notice, :warning, :error] do
        event = %Event{ts_us: 1, level: level, message: "m"}
        text = "h" |> Encode.ndjson("n", [event]) |> IO.iodata_to_binary()
        assert JSON.decode!(text)["level"] == Atom.to_string(level)
      end
    end

    test "what JSON cannot spell is made printable, and the record is sent" do
      event = %Event{
        ts_us: 1,
        level: :error,
        message: "exited: " <> <<255, 254>>,
        fields: %{"reason" => {:shutdown, :brutal}, "pid" => self(), "kind" => :crashed}
      }

      line = "h" |> Encode.ndjson("n", [event]) |> IO.iodata_to_binary() |> JSON.decode!()

      assert String.valid?(line["_msg"])
      assert line["_msg"] =~ "exited: "
      assert line["reason"] == "{:shutdown, :brutal}"
      assert line["pid"] == inspect(self())
      assert line["kind"] == "crashed"
      assert line["_time"] == 1
    end
  end

  describe "what is not text" do
    test "is made text: bytes replaced, an atom by its name, the rest as it is inspected" do
      assert Encode.printable("exited: " <> <<255, 254>>) == "exited: \uFFFD\uFFFD"
      assert Encode.printable(:crashed) == "crashed"
      assert Encode.printable({:shutdown, :brutal}) == "{:shutdown, :brutal}"
      assert Encode.printable(self()) == inspect(self())

      assert Encode.printable(%{
               "reason" => <<255>>,
               "n" => 1,
               kind: :crashed,
               at: ["a", <<254>>]
             }) ==
               %{"reason" => "\uFFFD", "n" => 1, "kind" => "crashed", "at" => ["a", "\uFFFD"]}
    end

    test "leaves a number a number and a flag a flag" do
      assert Encode.printable(4242) === 4242
      assert Encode.printable(6.0e-5) === 6.0e-5
      assert Encode.printable(true) === true
      assert Encode.printable(nil) === nil
    end

    test "is what a plane would have been sent" do
      fields = %{"reason" => "bytes " <> <<255, 254>>, "kind" => :crashed, "pid" => self()}
      event = %Event{ts_us: 1, level: :error, message: "m", fields: fields}
      line = "h" |> Encode.ndjson("n", [event]) |> IO.iodata_to_binary() |> JSON.decode!()

      assert Encode.printable(fields) == Map.take(line, Map.keys(fields))
    end

    test "gives back what is text already, and builds nothing" do
      fields = %{"pid" => "<0.7.0>", "reductions" => 4242, "crashed" => true, "at" => ["a"]}
      assert :erts_debug.same(Encode.printable(fields), fields)
    end
  end

  describe "spans" do
    defp span(service, parent, ok) do
      %Span{
        trace_id: :binary.copy(<<0xAB>>, 16),
        span_id: :binary.copy(<<0x01>>, 8),
        parent_span_id: parent,
        name: "Shop.Worker",
        service: service,
        ok: ok,
        ending: "exited: killed",
        start_ns: 1_753_000_000_000_000_000,
        duration_ns: 2_500_000_000,
        attributes: %{
          "process.reductions" => 4242,
          "process.cpu_seconds" => 2.5,
          "process.trapping" => true,
          "process.name" => "shop_worker"
        }
      }
    end

    defp exported(spans) do
      "ohm" |> Encode.otlp_json("app@ohm", spans) |> IO.iodata_to_binary() |> JSON.decode!()
    end

    test "spans are exported under the application they ran in" do
      spans = [
        span("shop", nil, true),
        span("kernel", :binary.copy(<<0x02>>, 8), false),
        span("shop", nil, nil)
      ]

      assert %{"resourceSpans" => [kernel, shop]} = exported(spans)

      assert shop["resource"]["attributes"] == [
               %{"key" => "host.name", "value" => %{"stringValue" => "ohm"}},
               %{"key" => "service.instance.id", "value" => %{"stringValue" => "app@ohm"}},
               %{"key" => "service.name", "value" => %{"stringValue" => "shop"}}
             ]

      assert [%{"scope" => scope, "spans" => of_shop}] = shop["scopeSpans"]
      assert scope == Encode.scope()
      assert length(of_shop) == 2
      assert Enum.at(of_shop, 0)["status"]["code"] == 1
      assert Enum.at(of_shop, 1)["status"]["code"] == 0
      refute Map.has_key?(Enum.at(of_shop, 0), "parentSpanId")

      assert [%{"spans" => [one]}] = kernel["scopeSpans"]
      assert one["traceId"] == String.duplicate("ab", 16)
      assert one["spanId"] == String.duplicate("01", 8)
      assert one["parentSpanId"] == String.duplicate("02", 8)
      assert one["name"] == "Shop.Worker"
      assert one["kind"] == 1
      assert one["startTimeUnixNano"] == "1753000000000000000"
      assert one["endTimeUnixNano"] == "1753000002500000000"
      assert one["status"] == %{"code" => 2, "message" => "exited: killed"}

      attribute = fn key ->
        Enum.find_value(one["attributes"], fn a -> a["key"] == key && a["value"] end)
      end

      assert attribute.("process.reductions") == %{"intValue" => 4242}
      assert attribute.("process.cpu_seconds") == %{"doubleValue" => 2.5}
      assert attribute.("process.trapping") == %{"boolValue" => true}
      assert attribute.("process.name") == %{"stringValue" => "shop_worker"}
    end

    test "an integer is sent as a number, and not as the string OTLP would write" do
      text = "h" |> Encode.otlp_json("n", [span("shop", nil, true)]) |> IO.iodata_to_binary()
      assert text =~ ~s("intValue":4242)
      refute text =~ ~s("intValue":"4242")
    end

    test "attributes are in the order of their keys, so the same spans are the same bytes" do
      assert %{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [one]}]}]} =
               exported([span("shop", nil, true)])

      keys = Enum.map(one["attributes"], & &1["key"])
      assert keys == Enum.sort(keys)

      spans = [span("shop", nil, true), span("kernel", nil, false)]

      assert IO.iodata_to_binary(Encode.otlp_json("h", "n", spans)) ==
               IO.iodata_to_binary(Encode.otlp_json("h", "n", spans))
    end

    test "a value of any other kind is sent as it would be inspected" do
      assert Encode.any_value({:shutdown, :normal}) == %{"stringValue" => "{:shutdown, :normal}"}
      assert Encode.any_value(:killed) == %{"stringValue" => ":killed"}
      assert Encode.any_value(nil) == %{"stringValue" => "nil"}
      assert Encode.any_value([1, 2]) == %{"stringValue" => "[1, 2]"}
      # A boolean is an atom, and is not sent as one.
      assert Encode.any_value(false) == %{"boolValue" => false}
    end

    test "the scope is this collector and its version" do
      assert Encode.scope() == %{
               "name" => "timeless-beam-acct",
               "version" => to_string(Application.spec(:timeless_beam_acct, :vsn))
             }
    end

    test "the resource is the application, in the node, on the host" do
      assert Encode.resource("ohm", "app@ohm", span("shop", nil, true)) == %{
               "service.name" => "shop",
               "host.name" => "ohm",
               "service.instance.id" => "app@ohm"
             }
    end
  end
end
