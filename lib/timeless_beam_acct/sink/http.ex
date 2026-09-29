defmodule TimelessBeamAcct.Sink.Http do
  @moduledoc """
  Push to the Timeless metrics, logs, and traces planes.

  This is the sink the canvas reads from: the planes own their databases,
  and everything else reaches them over HTTP.

  | signal | is posted to | as |
  |---|---|---|
  | samples | `<metrics_url>/api/v1/import/prometheus` | `text/plain` |
  | records | `<logs_url>/insert/jsonline` | `application/x-ndjson` |
  | spans | `<traces_url>/insert/opentelemetry/v1/traces` | `application/json` |

  ## Options

  | option | default | |
  |---|---|---|
  | `:metrics_url` | `http://127.0.0.1:8428` | the metrics plane |
  | `:logs_url` | `http://127.0.0.1:9428` | the logs plane |
  | `:traces_url` | `http://127.0.0.1:10428` | the traces plane |
  | `:token` | | a bearer token, for planes started with authentication required |
  | `:timeout` | `5` | seconds a plane is given to answer, for the whole of a request: a number, or written as `"5s"` or `"1m"` |
  | `:backlog` | `360` | ticks kept while a plane is unreachable. At a ten-second interval the default holds an hour |

  ## What waits

  A tick is up to three bodies, one for each plane, and only for the parts
  of the tick that have something in them. Each is encoded when it is
  written and put at the back of what is waiting. Every sample, record,
  and span carries its own time, so one that waits is stored at the time
  it was taken and not at the time it arrived.

  What is waiting is sent oldest first. When more than `backlog * 3`
  bodies are waiting the oldest are dropped, and counted: an hour of the
  past is worth less than the memory of the node being watched.

  A status outside 200..299 is a failure, and the body is kept to be sent
  again: a plane that is starting, or full, or asks who is asking, may
  answer otherwise later.

  Except where the plane says the body itself is what is wrong (400, 413,
  415, 422). It would say so again, and everything behind the body would
  wait for the hour it takes to be dropped. Such a body is let go, and
  counted, and the write is still said to have failed.

  ## One thing differs from timeless-acct on purpose

  There, the first failure ends the drain, whichever plane it came from.
  Here, a failure ends the drain for that plane only. The three planes are
  three servers, and if the logs plane is down the samples must still
  arrive: a graph with an hour missing because records could not be
  stored is a worse account than one without the records.

  So each plane has in effect a backlog of its own. A plane that fails is
  not asked again in the same drain, which keeps the cost of a plane that
  is down at one timeout a drain rather than one for every body waiting.
  The bodies of the other planes are sent, each plane's in the order they
  were written. The capacity is still of everything waiting together, and
  the oldest is still what is dropped.
  """

  @behaviour TimelessBeamAcct.Sink

  alias TimelessBeamAcct.{Clock, Encode, Http, Tick}

  @planes [:metrics, :logs, :traces]

  @paths %{
    metrics: "/api/v1/import/prometheus",
    logs: "/insert/jsonline",
    traces: "/insert/opentelemetry/v1/traces"
  }

  @content_types %{
    metrics: "text/plain",
    logs: "application/x-ndjson",
    traces: "application/json"
  }

  @defaults [
    metrics_url: "http://127.0.0.1:8428",
    logs_url: "http://127.0.0.1:9428",
    traces_url: "http://127.0.0.1:10428",
    token: nil,
    timeout: 5,
    backlog: 360
  ]

  # How long a plane is given to say that it is there.
  @check_timeout_ms 2_000
  # The most of an answer that is put in a message.
  @shown 200
  # What a plane answers when it is the body that is wrong.
  @refusals [400, 413, 415, 422]

  @type plane :: :metrics | :logs | :traces

  @type t :: %__MODULE__{
          bases: %{plane() => String.t()},
          endpoints: %{plane() => String.t()},
          token: String.t() | nil,
          timeout_ms: pos_integer(),
          backlog: :queue.queue({plane(), binary()}),
          waiting: non_neg_integer(),
          capacity: pos_integer(),
          dropped: non_neg_integer(),
          refused: non_neg_integer()
        }

  @enforce_keys [:bases, :endpoints, :timeout_ms, :capacity]
  defstruct [
    :bases,
    :endpoints,
    :token,
    :timeout_ms,
    :capacity,
    backlog: :queue.new(),
    waiting: 0,
    dropped: 0,
    refused: 0
  ]

  @doc """
  The sink, from its options. Nothing is sent, and the planes need not be
  there: what cannot be sent waits.
  """
  @impl true
  @spec init(keyword()) :: {:ok, t()} | {:error, String.t()}
  def init(opts) when is_list(opts) do
    with :ok <- known(opts),
         opts = Keyword.merge(@defaults, opts),
         {:ok, bases} <- bases(opts),
         {:ok, token} <- token(opts[:token]),
         {:ok, timeout_ms} <- timeout(opts[:timeout]),
         {:ok, backlog} <- backlog(opts[:backlog]) do
      {:ok,
       %__MODULE__{
         bases: bases,
         endpoints: Map.new(bases, fn {plane, base} -> {plane, base <> @paths[plane]} end),
         token: token,
         timeout_ms: timeout_ms,
         # A tick is up to three bodies, one per plane.
         capacity: max(backlog, 1) * 3
       }}
    end
  end

  def init(opts), do: {:error, "the options are #{inspect(opts)}: expected a keyword list"}

  defp known(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- Keyword.keys(@defaults) do
        [] -> :ok
        [unknown | _] -> {:error, "unknown option #{inspect(unknown)} of the :http sink"}
      end
    else
      {:error, "the options are #{inspect(opts)}: expected a keyword list"}
    end
  end

  defp bases(opts) do
    Enum.reduce_while(@planes, {:ok, %{}}, fn plane, {:ok, bases} ->
      key = :"#{plane}_url"

      case base(opts[key]) do
        {:ok, base} ->
          {:cont, {:ok, Map.put(bases, plane, base)}}

        :error ->
          {:halt,
           {:error, "#{inspect(key)} is #{inspect(opts[key])}: expected an http or https URL"}}
      end
    end)
  end

  defp base(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, query: nil, fragment: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, String.trim_trailing(url, "/")}

      _ ->
        :error
    end
  end

  defp base(_url), do: :error

  defp token(nil), do: {:ok, nil}

  defp token(token) when is_binary(token) do
    if token != "" and String.printable?(token) and not String.contains?(token, ["\r", "\n"]),
      do: {:ok, token},
      else: {:error, ":token cannot be sent as a header"}
  end

  defp token(_token), do: {:error, ":token is not a string"}

  defp timeout(written) when is_number(written) or is_binary(written) do
    case Clock.parse_span(written) do
      {:ok, seconds} when seconds > 0 -> {:ok, max(round(seconds * 1000), 1)}
      {:ok, _none} -> {:error, ":timeout must be more than no time"}
      {:error, why} -> {:error, ":timeout: #{why}"}
    end
  end

  defp timeout(other), do: {:error, ":timeout is #{inspect(other)}: expected a length of time"}

  defp backlog(ticks) when is_integer(ticks) and ticks >= 0, do: {:ok, ticks}
  defp backlog(other), do: {:error, ":backlog is #{inspect(other)}: expected a count of ticks"}

  @doc """
  Encode what the tick produced, put it behind what is waiting, and send
  what is waiting.

  The error says what the first plane to fail said, how many bodies are
  waiting, and how many have been dropped since the sink was made.
  """
  @impl true
  @spec write(t(), String.t(), String.t(), Tick.t()) :: {:ok, t()} | {:error, String.t(), t()}
  def write(%__MODULE__{} = state, host, node, %Tick{} = tick) do
    state =
      state
      |> wait(:metrics, tick.metrics.count > 0, fn ->
        Encode.prometheus_text(host, node, tick.metrics)
      end)
      |> wait(:logs, tick.events != [], fn -> Encode.ndjson(host, node, tick.events) end)
      |> wait(:traces, tick.spans != [], fn -> Encode.otlp_json(host, node, tick.spans) end)
      |> drop_oldest()

    case drain(state) do
      {:ok, state} ->
        {:ok, state}

      {:error, error, state} ->
        {:error, "#{error} (#{state.waiting} waiting, #{state.dropped} dropped so far)", state}
    end
  end

  @doc "Send what is waiting."
  @impl true
  @spec flush(t()) :: {:ok, t()} | {:error, String.t(), t()}
  def flush(%__MODULE__{} = state), do: drain(state)

  @doc """
  Nothing is owed to a plane at the end: what it answered for, it has.
  What is still waiting is lost with the sink, and `flush/1` is what would
  have sent it.
  """
  @impl true
  @spec close(t()) :: :ok
  def close(%__MODULE__{}), do: :ok

  @impl true
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{endpoints: endpoints}) do
    "http: #{endpoints.metrics}, #{endpoints.logs}, and #{endpoints.traces}"
  end

  @doc "How many bodies are waiting to be sent."
  @spec waiting(t()) :: non_neg_integer()
  def waiting(%__MODULE__{waiting: waiting}), do: waiting

  @doc "How many bodies have been dropped, unsent, since the sink was made."
  @spec dropped(t()) :: non_neg_integer()
  def dropped(%__MODULE__{dropped: dropped}), do: dropped

  @doc "How many bodies a plane has refused, and were let go."
  @spec refused(t()) :: non_neg_integer()
  def refused(%__MODULE__{refused: refused}), do: refused

  @doc """
  Whether each plane can be reached, for telling a person.

  Each is asked for `<url>/health` and given two seconds, all three at
  once. The URL in the result is the one the sink was given, which is the
  one a person would have to correct.

  The planes answer for `/health` without asking who is asking, so this
  says that a plane is there and not that it will accept the token.
  """
  @spec check(t()) :: [{plane(), String.t(), {:ok, String.t()} | {:error, String.t()}}]
  def check(%__MODULE__{bases: bases} = state) do
    @planes
    |> Enum.map(fn plane ->
      base = Map.fetch!(bases, plane)
      {plane, base, Task.async(fn -> health(state, base) end)}
    end)
    |> Enum.map(fn {plane, base, task} -> {plane, base, Task.await(task, :infinity)} end)
  end

  defp health(state, base) do
    case Http.get(base <> "/health", authorization(state), @check_timeout_ms) do
      {:ok, status, body} when status in 200..299 ->
        {:ok, answering(body)}

      {:ok, status, body} ->
        {:error, "/health answered #{status}" <> detail(body)}

      {:error, reason} ->
        {:error, Http.format_error(reason)}
    end
  end

  defp answering(body) do
    line = body |> String.split() |> Enum.join(" ")

    if line != "" and String.length(line) <= @shown and String.printable?(line),
      do: "answering: " <> line,
      else: "answering"
  end

  ## What is waiting

  defp wait(state, _plane, false, _encode), do: state

  defp wait(state, plane, true, encode) do
    # Kept as one binary: what waits may wait for an hour, and a binary is
    # a fraction of the size of the list it was built as.
    body = IO.iodata_to_binary(encode.())
    %{state | backlog: :queue.in({plane, body}, state.backlog), waiting: state.waiting + 1}
  end

  defp drop_oldest(%__MODULE__{waiting: waiting, capacity: capacity} = state)
       when waiting > capacity do
    drop_oldest(%{
      state
      | backlog: :queue.drop(state.backlog),
        waiting: waiting - 1,
        dropped: state.dropped + 1
    })
  end

  defp drop_oldest(state), do: state

  # Oldest first. A plane that fails is not asked again, and what was for
  # it stays where it was in the order.
  defp drain(%__MODULE__{backlog: backlog} = state) do
    {kept, _down, first_error, refused} =
      backlog
      |> :queue.to_list()
      |> Enum.reduce({[], [], nil, 0}, fn {plane, body} = pending,
                                          {kept, down, first_error, refused} ->
        if plane in down do
          {[pending | kept], down, first_error, refused}
        else
          case post(state, plane, body) do
            :ok -> {kept, down, first_error, refused}
            {:refused, error} -> {kept, down, first_error || error, refused + 1}
            {:error, error} -> {[pending | kept], [plane | down], first_error || error, refused}
          end
        end
      end)

    state = %{
      state
      | backlog: kept |> Enum.reverse() |> :queue.from_list(),
        waiting: length(kept),
        refused: state.refused + refused
    }

    case first_error do
      nil -> {:ok, state}
      error -> {:error, error, state}
    end
  end

  defp post(state, plane, body) do
    url = Map.fetch!(state.endpoints, plane)
    headers = [{"Content-Type", Map.fetch!(@content_types, plane)} | authorization(state)]

    case Http.post(url, body, headers, state.timeout_ms) do
      {:ok, status, _body} when status in 200..299 ->
        :ok

      {:ok, status, body} when status in @refusals ->
        {:refused, "#{url} refused what it was sent, with #{status}" <> detail(body)}

      {:ok, status, body} ->
        {:error, "#{url} answered #{status}" <> detail(body)}

      {:error, reason} ->
        {:error, "#{url}: #{Http.format_error(reason)}"}
    end
  end

  defp authorization(%__MODULE__{token: nil}), do: []
  defp authorization(%__MODULE__{token: token}), do: [{"Authorization", "Bearer " <> token}]

  # What a plane said, as the end of a sentence.
  defp detail(body) do
    case body |> String.replace_invalid() |> String.trim() do
      "" -> ""
      said -> ": " <> String.slice(said, 0, @shown)
    end
  end
end
