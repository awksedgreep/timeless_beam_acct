defmodule TimelessBeamAcct.Encode do
  @moduledoc """
  Wire encodings shared by every sink.

  Metrics travel as Prometheus exposition text, records as NDJSON, and
  spans as an OTLP export request in JSON. The stores running in this node
  and the planes reached over HTTP accept exactly these, so there is one
  encoder and the sinks cannot drift apart.

  Everything is stamped with `host` and with `node`. A host runs more than
  one node, and a node's name is the only thing that tells two of them
  apart, so it goes beside the host on every sample, record, and span
  rather than being left to each collector to remember.

  The functions return iodata where building a binary would only copy
  bytes that are about to be written to a socket. Every result is accepted
  by `IO.iodata_to_binary/1`.

  Names and values are expected to be valid UTF-8. Where a record or a
  span holds something that is not, or a value JSON has no spelling for,
  it is made printable and sent rather than raised on: one process with a
  strange name must not cost a tick its records.
  """

  alias TimelessBeamAcct.{Batch, Event, Span}

  @version Mix.Project.config()[:version]
  @scope_name "timeless-beam-acct"

  # A float that is whole and smaller than this is written as an integer.
  # Below it every whole float is exactly the integer it prints as.
  @whole_below 1.0e15

  @doc """
  `name{host="h",node="n",k="v"} value timestamp_ms`, one line per sample,
  in the order the samples were added.

  Exposition timestamps are milliseconds by specification; the store
  normalizes them back to the seconds it keeps.

  A whole value is written without a fraction, `12` and not `12.0`, which
  is what most values are and is shorter. Any other float is written as
  the shortest text that parses back to the same float, so the value
  survives the text hop exactly.
  """
  @spec prometheus_text(String.t(), String.t(), Batch.t()) :: iodata()
  def prometheus_text(host, node, %Batch{} = batch) when is_binary(host) and is_binary(node) do
    ts_ms = Integer.to_string(batch.ts * 1000)

    # The same for every line, so it is built once.
    opening = IO.iodata_to_binary([~s({host="), escape(host), ~s(",node="), escape(node), ?"])

    for {name, labels, value} <- Batch.samples(batch) do
      [name, opening, labels(labels), "} ", value(value), ?\s, ts_ms, ?\n]
    end
  end

  defp labels([]), do: []
  defp labels([{key, value} | rest]), do: [?,, key, ~s(="), escape(value), ?" | labels(rest)]

  defp escape(value) when is_binary(value) do
    case :binary.match(value, ["\\", "\"", "\n"]) do
      :nomatch ->
        value

      _ ->
        String.replace(value, ["\\", "\"", "\n"], fn
          "\\" -> "\\\\"
          "\"" -> "\\\""
          "\n" -> "\\n"
        end)
    end
  end

  defp escape(value), do: value |> to_string() |> escape()

  @doc """
  A sample's value as it is written.
  """
  @spec value(number()) :: String.t()
  def value(value) when is_integer(value), do: Integer.to_string(value)

  def value(value) when is_float(value) do
    whole = trunc(value)

    cond do
      abs(value) >= @whole_below or whole != value -> Float.to_string(value)
      # Negative zero is a float of its own, and is written as one.
      whole == 0 and match?(<<1::1, _::63>>, <<value::float>>) -> "-0"
      true -> Integer.to_string(whole)
    end
  end

  @doc """
  The metadata stored with a record: its fields plus `host` and `node`.
  """
  @spec event_metadata(String.t(), String.t(), Event.t()) :: %{String.t() => term()}
  def event_metadata(host, node, %Event{fields: fields}) do
    fields
    |> Map.new()
    |> Map.put("host", host)
    |> Map.put("node", node)
  end

  @doc """
  One JSON object per line, in the shape `/insert/jsonline` reads: the
  metadata, the message as `_msg`, the time as `_time` in epoch
  microseconds, and the level.
  """
  @spec ndjson(String.t(), String.t(), [Event.t()]) :: iodata()
  def ndjson(host, node, events) when is_list(events) do
    for %Event{} = event <- events do
      object =
        host
        |> event_metadata(node, event)
        |> Map.put("_msg", event.message)
        |> Map.put("_time", event.ts_us)
        |> Map.put("level", Atom.to_string(event.level))

      [json(object), ?\n]
    end
  end

  @doc "What every span of this collector's is said to come from."
  @spec scope() :: %{String.t() => String.t()}
  def scope, do: %{"name" => @scope_name, "version" => @version}

  @doc """
  What a span's resource is: the application, in the node, on the host.
  """
  @spec resource(String.t(), String.t(), Span.t()) :: %{String.t() => String.t()}
  def resource(host, node, %Span{service: service}) do
    %{"service.name" => service, "host.name" => host, "service.instance.id" => node}
  end

  @doc """
  An OTLP export request, as JSON: the spans, under the resource each
  belongs to.

  There is one resource for each application, in the order of their names.
  Attributes are written in the order of their keys, so the same spans are
  always the same bytes.
  """
  @spec otlp_json(String.t(), String.t(), [Span.t()]) :: iodata()
  def otlp_json(host, node, spans) when is_list(spans) do
    resource_spans =
      spans
      |> Enum.group_by(& &1.service)
      |> Enum.sort_by(fn {service, _spans} -> service end)
      |> Enum.map(fn {_service, [first | _] = of_service} ->
        %{
          "resource" => %{"attributes" => key_values(resource(host, node, first))},
          "scopeSpans" => [%{"scope" => scope(), "spans" => Enum.map(of_service, &span/1)}]
        }
      end)

    json(%{"resourceSpans" => resource_spans})
  end

  defp span(%Span{} = span) do
    encoded = %{
      "traceId" => Span.hex(span.trace_id),
      "spanId" => Span.hex(span.span_id),
      "name" => span.name,
      # Internal.
      "kind" => 1,
      "startTimeUnixNano" => Integer.to_string(span.start_ns),
      "endTimeUnixNano" => Integer.to_string(span.start_ns + span.duration_ns),
      "attributes" => key_values(span.attributes),
      "status" => %{"code" => status_code(span.ok), "message" => span.ending}
    }

    case span.parent_span_id do
      nil -> encoded
      parent -> Map.put(encoded, "parentSpanId", Span.hex(parent))
    end
  end

  defp status_code(nil), do: 0
  defp status_code(true), do: 1
  defp status_code(false), do: 2

  defp key_values(attributes) do
    attributes
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> %{"key" => key, "value" => any_value(value)} end)
  end

  @doc """
  A value as OTLP writes one: tagged with its type.

  OTLP writes a 64-bit integer as a string, since a JSON number cannot be
  trusted to hold one, and readers are to take either. The traces plane
  keeps what it is given as it is given, and an integer sent as a string
  is stored as a string. Nothing counted here comes near the 53 bits a
  JSON number holds exactly, so integers are sent as numbers, and are the
  same in the planes as in a local store.
  """
  @spec any_value(term()) :: %{String.t() => term()}
  def any_value(value) when is_boolean(value), do: %{"boolValue" => value}
  def any_value(value) when is_integer(value), do: %{"intValue" => value}
  def any_value(value) when is_float(value), do: %{"doubleValue" => value}
  def any_value(value) when is_binary(value), do: %{"stringValue" => value}
  def any_value(value), do: %{"stringValue" => inspect(value)}

  # Encoding is tried as it is given, which is all that is ever needed when
  # the collector made the term. Only if that fails is the term walked and
  # made printable.
  defp json(term) do
    JSON.encode_to_iodata!(term)
  rescue
    _ -> term |> printable() |> JSON.encode_to_iodata!()
  end

  defp printable(value) when is_binary(value) do
    if String.valid?(value), do: value, else: String.replace_invalid(value)
  end

  defp printable(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp printable(value) when is_atom(value), do: Atom.to_string(value)
  defp printable(value) when is_list(value), do: Enum.map(value, &printable/1)

  defp printable(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} -> {printable_key(key), printable(inner)} end)
  end

  defp printable(value), do: inspect(value)

  defp printable_key(key) when is_binary(key), do: printable(key)
  defp printable_key(key) when is_atom(key), do: Atom.to_string(key)
  defp printable_key(key), do: inspect(key)
end
