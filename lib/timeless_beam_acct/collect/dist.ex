defmodule TimelessBeamAcct.Collect.Dist do
  @moduledoc """
  Connections to other nodes: how many, and what passes over each.

  | metric | is | label |
  |---|---|---|
  | `beam_dist_nodes` | nodes connected, hidden ones too | |
  | `beam_dist_in_bytes_per_sec`, `beam_dist_out_bytes_per_sec` | bytes received from the peer, and sent to it | `peer` |
  | `beam_dist_queue_bytes` | bytes handed to the connection and not yet sent | `peer` |

  `beam_dist_nodes` is reported by a node that is not distributed as well:
  it is 0, and a line at 0 is not the same as no line.

  ## Where the figures come from

  `:erlang.system_info(:dist_ctrl)` gives the controller of each
  connection. Over TCP, which is what a node uses unless told otherwise,
  the controller is a port, and the port keeps the counters of its socket:
  `:inet.getstat/2` reads `recv_oct`, `send_oct`, and `send_pend`. That is
  three numbers from one call, and asks nothing of the process that owns
  the connection.

  `:net_kernel.nodes_info()` is not used. It sends a message to the owner
  of every connection and waits for each to answer, and what it returns as
  `in` and `out` are packets, not bytes.

  With distribution over TLS, or over the `socket` backend, the controller
  is a process, and its socket is its own. The VM has the figures
  (`:erlang.dist_get_stat(handle)`) and gives them only to who holds the
  connection's handle, which is that process. Such a connection is counted
  in `beam_dist_nodes` and has no series of its own.

  `beam_dist_queue_bytes` is what the port has taken and the socket has
  not. While the port is busy the VM holds back what it would hand over
  next, and suspends the senders; how much it holds is not in it, because
  there is no way to ask.

  ## A connection that was made again

  A peer that went away and came back has a new controller, and counters
  that started again at zero. Readings are kept by peer and controller
  together, so the new connection is recognised as new and has no rate
  until its second reading, even when it has already carried more than the
  old one had.
  """

  alias TimelessBeamAcct.{Batch, Options}

  @typedoc "A connection: the peer, and the port or process that controls it."
  @type connection :: {peer :: node(), controller :: port() | pid()}

  @typedoc "The counters of one connection, as its socket keeps them."
  @type counters :: %{
          in_bytes: non_neg_integer(),
          out_bytes: non_neg_integer(),
          queue_bytes: non_neg_integer()
        }

  @typedoc """
  The connections at one instant. A connection whose counters could not be
  read is counted in `nodes` and is not in `connections`.
  """
  @type reading :: %{nodes: non_neg_integer(), connections: %{connection() => counters()}}

  @type state :: %__MODULE__{previous: reading() | nil, at: float() | nil}

  defstruct previous: nil, at: nil

  @doc "A collector that has read nothing yet."
  @spec new(Options.t()) :: state()
  def new(%Options{}), do: %__MODULE__{}

  @doc """
  Read the connections, and add this instant's samples to the batch.

  `mono` is monotonic time in seconds. Rates are over the time since the
  call before this one.
  """
  @spec collect(state(), Batch.t(), float()) :: {state(), Batch.t()}
  def collect(%__MODULE__{} = state, %Batch{} = batch, mono) when is_number(mono) do
    reading = read()
    seconds = if state.at, do: mono - state.at
    {%{state | previous: reading, at: mono}, report(batch, state.previous, reading, seconds)}
  end

  @doc "There is nothing to give back."
  @spec close(state()) :: :ok
  def close(%__MODULE__{}), do: :ok

  @doc """
  The samples of one reading, and of the difference between it and the one
  before. `seconds` is the time between the two.

  A connection that was not in the reading before has no rates.
  """
  @spec report(Batch.t(), reading() | nil, reading(), number() | nil) :: Batch.t()
  def report(%Batch{} = batch, previous, %{nodes: nodes, connections: connections}, seconds) do
    before =
      if is_map(previous) and is_number(seconds) and seconds > 0,
        do: previous.connections,
        else: %{}

    batch = Batch.push(batch, "beam_dist_nodes", nodes)

    connections
    |> Enum.sort_by(fn {{peer, _controller}, _counters} -> peer end)
    |> Enum.reduce(batch, fn {{peer, _controller} = connection, counters}, batch ->
      labels = [{"peer", Atom.to_string(peer)}]
      batch = Batch.push(batch, "beam_dist_queue_bytes", labels, counters.queue_bytes)

      case before do
        %{^connection => was} ->
          batch
          |> Batch.push(
            "beam_dist_in_bytes_per_sec",
            labels,
            Batch.rate(counters.in_bytes, was.in_bytes, seconds)
          )
          |> Batch.push(
            "beam_dist_out_bytes_per_sec",
            labels,
            Batch.rate(counters.out_bytes, was.out_bytes, seconds)
          )

        %{} ->
          batch
      end
    end)
  end

  @doc false
  @spec read() :: reading()
  def read do
    connections =
      for {peer, controller} <- controllers(),
          counters = counters(controller),
          into: %{},
          do: {{peer, controller}, counters}

    %{nodes: length(Node.list(:connected)), connections: connections}
  end

  defp controllers do
    case :erlang.system_info(:dist_ctrl) do
      controllers when is_list(controllers) -> controllers
      _ -> []
    end
  rescue
    ArgumentError -> []
  end

  # `nil` for a connection that does not keep its counters where they can
  # be read, or that closed since it was listed.
  defp counters(port) when is_port(port) do
    with {:ok, stats} <- :inet.getstat(port, [:recv_oct, :send_oct, :send_pend]),
         {_, received} when is_integer(received) <- List.keyfind(stats, :recv_oct, 0),
         {_, sent} when is_integer(sent) <- List.keyfind(stats, :send_oct, 0),
         {_, waiting} when is_integer(waiting) <- List.keyfind(stats, :send_pend, 0) do
      %{in_bytes: received, out_bytes: sent, queue_bytes: waiting}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp counters(_controller), do: nil
end
