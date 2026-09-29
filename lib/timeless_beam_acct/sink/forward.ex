defmodule TimelessBeamAcct.Sink.Forward do
  @moduledoc """
  Hand each tick to a process, as a message.

  This is for whoever wants what the collector sees and has a use for it
  that is not storing it: a test, a LiveView, a process that decides
  something from it. The tick is handed over as it is, not encoded, since
  the process is in a node that has the structs.

  | when | the process is sent |
  |---|---|
  | a tick is written | `{:timeless_beam_acct, :tick, host, node, %TimelessBeamAcct.Tick{}}` |
  | the sink is flushed | `{:timeless_beam_acct, :flush}` |
  | the sink is closed | `{:timeless_beam_acct, :close}` |

  A message is sent and not waited on. The writer is not held by a process
  that is slow to read, and a process that does not read at all has a
  mailbox that grows: what is forwarded to should keep up, or drop.

  ## Options

  | option | | |
  |---|---|---|
  | `:to` | required | a pid, a registered name, or `{name, node}` |

  A name is looked up each time, so a process that is restarted under the
  same name is found again. While nothing has the name a write is
  `{:error, :noproc, state}`, which the writer reports and goes on from:
  the tick is not kept. A process in a node that is not connected is
  `{:error, :noconnection, state}`, for the same reason.
  """

  @behaviour TimelessBeamAcct.Sink

  alias TimelessBeamAcct.Tick

  @type destination :: pid() | atom() | {atom(), node()}
  @type t :: %__MODULE__{to: destination()}

  @enforce_keys [:to]
  defstruct [:to]

  @impl true
  @spec init(keyword()) :: {:ok, t()} | {:error, String.t()}
  def init(opts) when is_list(opts) do
    case Keyword.keys(opts) -- [:to] do
      [] ->
        case Keyword.fetch(opts, :to) do
          {:ok, to} -> destination(to)
          :error -> {:error, "the :forward sink needs :to, the process ticks are handed to"}
        end

      [unknown | _] ->
        {:error, "unknown option #{inspect(unknown)} of the :forward sink"}
    end
  end

  defp destination(to) when is_pid(to), do: {:ok, %__MODULE__{to: to}}

  defp destination(to) when is_atom(to) and to not in [nil, true, false],
    do: {:ok, %__MODULE__{to: to}}

  defp destination({name, node} = to)
       when is_atom(name) and is_atom(node) and name not in [nil, true, false],
       do: {:ok, %__MODULE__{to: to}}

  defp destination(to),
    do: {:error, ":to is #{inspect(to)}: expected a pid, a registered name, or {name, node}"}

  @impl true
  @spec write(t(), String.t(), String.t(), Tick.t()) ::
          {:ok, t()} | {:error, :noproc | :noconnection, t()}
  def write(%__MODULE__{} = state, host, node, %Tick{} = tick) do
    forward(state, {:timeless_beam_acct, :tick, host, node, tick})
  end

  @impl true
  @spec flush(t()) :: {:ok, t()} | {:error, :noproc | :noconnection, t()}
  def flush(%__MODULE__{} = state), do: forward(state, {:timeless_beam_acct, :flush})

  @impl true
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = state) do
    forward(state, {:timeless_beam_acct, :close})
    :ok
  end

  @impl true
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{to: to}), do: "forward: to #{inspect(to)}"

  # Sending to a name nothing has raises, so the name is looked up. The
  # process may still end between the two, and then the message goes
  # nowhere, as one sent to a pid that has ended does.
  defp forward(%__MODULE__{to: name} = state, message) when is_atom(name) do
    case Process.whereis(name) do
      nil ->
        {:error, :noproc, state}

      pid ->
        send(pid, message)
        {:ok, state}
    end
  end

  # To another node only over a connection that is there: making one can
  # take as long as the network likes, and the writer has ticks to write.
  defp forward(%__MODULE__{to: to} = state, message) do
    case Process.send(to, message, [:noconnect]) do
      :ok -> {:ok, state}
      :noconnect -> {:error, :noconnection, state}
    end
  end
end
