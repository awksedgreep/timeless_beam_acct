defmodule TimelessBeamAcct.Batch do
  @moduledoc """
  Samples taken at one instant.

  Every metric is a gauge. The canvas reads the last value in a bucket and
  draws it, so a raw counter would plot as an ever-rising line and rewind
  to a meaningless number. Rates are taken here, once, the way sar records
  them.

  A sample is `{name, labels, value}`. The labels of one subject (a
  process, an application) are one list, shared by all of its samples.
  `host` and `node` are not in it; the sink adds them to everything.
  """

  @type labels :: [{String.t(), String.t()}]
  @type sample :: {String.t(), labels(), number()}
  @type t :: %__MODULE__{ts: integer(), samples: [sample()], count: non_neg_integer()}

  # `samples` is kept newest first.
  defstruct ts: 0, samples: [], count: 0

  @doc "An empty batch. `ts` is epoch seconds, the metrics unit."
  @spec new(integer()) :: t()
  def new(ts) when is_integer(ts), do: %__MODULE__{ts: ts}

  @doc """
  Add a sample.

  `nil` is dropped rather than stored: it comes from a zero-length interval
  or a counter that went backwards, and a gap is more honest than a made-up
  number on a graph.
  """
  @spec push(t(), String.t(), labels(), number() | nil) :: t()
  def push(batch, name, labels \\ [], value)

  def push(%__MODULE__{} = batch, _name, _labels, nil), do: batch

  def push(%__MODULE__{samples: samples, count: count} = batch, name, labels, value)
      when is_binary(name) and is_list(labels) and is_number(value) do
    %{batch | samples: [{name, labels, measured(value)} | samples], count: count + 1}
  end

  @doc "The samples, in the order they were added."
  @spec samples(t()) :: [sample()]
  def samples(%__MODULE__{samples: samples}), do: Enum.reverse(samples)

  @doc "The batch with nothing in it, at the same time."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = batch), do: %{batch | samples: [], count: 0}

  @doc """
  A value at the precision it was measured to: thousandths, or whole units
  from a thousand up.

  A rate is a difference of integer counters over a measured interval, and
  the digits past the first few are the interval's jitter, not the
  subject's behaviour. Storing them costs bytes on the wire and defeats the
  store's compression, which does best on short decimals.
  """
  @spec measured(number()) :: number()
  def measured(value) when is_integer(value), do: value

  def measured(value) when is_float(value) do
    if abs(value) >= 1000.0 do
      Float.round(value)
    else
      Float.round(value, 3)
    end
  end

  @doc """
  What a counter rose by each second. `nil` if no time passed, or if the
  counter went backwards: it belongs to something else now.
  """
  @spec rate(number(), number(), number()) :: float() | nil
  def rate(now, before, seconds) when now >= before and seconds > 0,
    do: (now - before) / seconds

  def rate(_now, _before, _seconds), do: nil

  @doc "`part` as a percentage of `whole`. `nil` if there is no whole."
  @spec pct(number(), number()) :: float() | nil
  def pct(part, whole) when whole > 0, do: 100.0 * part / whole
  def pct(_part, _whole), do: nil
end

defmodule TimelessBeamAcct.Event do
  @moduledoc """
  One record, stored as a log entry: a process that ended, or something the
  VM remarked on.

  `ts_us` is epoch microseconds, the unit the logs plane creates its table
  with. `fields` has string keys, and values that are strings, numbers, or
  booleans.
  """

  @type level :: :info | :notice | :warning | :error
  @type t :: %__MODULE__{
          ts_us: integer(),
          level: level(),
          message: String.t(),
          fields: %{String.t() => String.t() | number() | boolean()}
        }

  @enforce_keys [:ts_us, :level, :message]
  defstruct [:ts_us, :level, :message, fields: %{}]
end

defmodule TimelessBeamAcct.Span do
  @moduledoc """
  A process, from its start to its end, as a span of a trace.
  """

  @type t :: %__MODULE__{
          trace_id: <<_::128>>,
          span_id: <<_::64>>,
          parent_span_id: <<_::64>> | nil,
          name: String.t(),
          service: String.t(),
          ok: boolean() | nil,
          ending: String.t(),
          start_ns: integer(),
          duration_ns: non_neg_integer(),
          attributes: %{String.t() => String.t() | number() | boolean()}
        }

  @enforce_keys [:trace_id, :span_id, :name, :service, :start_ns, :duration_ns]
  defstruct [
    :trace_id,
    :span_id,
    # The process that started it, if that is part of the same trace.
    :parent_span_id,
    # What the process was: its group.
    :name,
    # The application it ran in, which is what runs in a node as a service
    # does in a system.
    :service,
    # `nil` if how it ended is not known.
    :ok,
    :start_ns,
    :duration_ns,
    # How it ended, in words.
    ending: "",
    attributes: %{}
  ]

  @doc "As the store spells it."
  @spec status(t()) :: :ok | :error | :unset
  def status(%__MODULE__{ok: true}), do: :ok
  def status(%__MODULE__{ok: false}), do: :error
  def status(%__MODULE__{ok: nil}), do: :unset

  @doc "An id as it is written: lowercase hexadecimal."
  @spec hex(binary()) :: String.t()
  def hex(id) when is_binary(id), do: Base.encode16(id, case: :lower)
end

defmodule TimelessBeamAcct.Tick do
  @moduledoc """
  What one tick produced.
  """

  alias TimelessBeamAcct.{Batch, Event, Span}

  @type t :: %__MODULE__{metrics: Batch.t(), events: [Event.t()], spans: [Span.t()]}

  @enforce_keys [:metrics]
  defstruct [:metrics, events: [], spans: []]

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{metrics: %Batch{count: 0}, events: [], spans: []}), do: true
  def empty?(%__MODULE__{}), do: false
end
