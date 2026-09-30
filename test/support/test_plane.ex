defmodule TimelessBeamAcct.TestPlane do
  @moduledoc """
  A plane for tests: it listens on 127.0.0.1, on a port the system picks,
  keeps what it is sent, and answers what it was told to.

  It reads one request from each connection and closes it, which is all
  `TimelessBeamAcct.Http` ever asks of a server.

      plane = start_supervised!(TestPlane)
      Http.post(TestPlane.url(plane) <> "/insert/jsonline", body, [], 500)
      [%{method: "POST", path: "/insert/jsonline", body: ^body}] = TestPlane.requests(plane)

  ## How it answers

  | mode | |
  |---|---|
  | `:content_length` | the body, with its length in a header. The default |
  | `:chunked` | the body in chunks of a few bytes |
  | `:until_close` | the body with no length, ended by closing |
  | `:hang` | nothing: the request is read and never answered |
  | `{:drip, ms}` | the answer a few bytes at a time, `ms` apart |

  ## What it answers

  The same to everything, unless it is given a function: `answer/2`, or
  the `:answer` option. The function is given each request, and returns
  the status and the body to answer it with. That is a plane that is
  asked questions, where the others are planes that are written to.

  ## Going down

  `stop_listening/1` closes the listening socket, so a connection is
  refused as it is by a plane that is not running. `listen/1` listens
  again on the same port, so whatever was pointed at the plane finds it
  where it was.

  While it is down the port is held by a socket that is bound to it and
  does not listen. Connections to it are refused all the same, and the
  system does not give the port to another test in the meantime. The
  system may refuse that socket the port, while connections the plane
  closed are still being forgotten. It is then bound as a socket that
  shares the port, which keeps it from anything that does not ask to
  share.
  """

  use GenServer

  @type request :: %{
          method: String.t(),
          path: String.t(),
          headers: %{String.t() => String.t()},
          body: binary()
        }
  @type mode :: :content_length | :chunked | :until_close | :hang | {:drip, pos_integer()}

  @listen [:binary, active: false, packet: :raw, reuseaddr: true, ip: {127, 0, 0, 1}, backlog: 64]

  ## What a test calls

  @doc """
  Start a plane. Options: `:status` (200), `:body` (empty), `:mode`
  (`:content_length`), and `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Where it is: `http://127.0.0.1:<port>`, with no slash after."
  @spec url(GenServer.server()) :: String.t()
  def url(plane), do: "http://127.0.0.1:#{port(plane)}"

  @doc "The port it listens on, which stays the same while it lives."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(plane), do: GenServer.call(plane, :port)

  @doc "What it was sent, in the order it arrived."
  @spec requests(GenServer.server()) :: [request()]
  def requests(plane), do: GenServer.call(plane, :requests)

  @doc "Forget what it was sent."
  @spec clear(GenServer.server()) :: :ok
  def clear(plane), do: GenServer.call(plane, :clear)

  @doc "Answer with this status and body from now on."
  @spec respond_with(GenServer.server(), pos_integer(), iodata()) :: :ok
  def respond_with(plane, status, body),
    do: GenServer.call(plane, {:respond_with, status, IO.iodata_to_binary(body)})

  @doc "Answer each request with what this returns for it, from now on."
  @spec answer(GenServer.server(), (request() -> {pos_integer(), iodata()})) :: :ok
  def answer(plane, fun) when is_function(fun, 1), do: GenServer.call(plane, {:answer, fun})

  @doc "Answer in this way from now on."
  @spec mode(GenServer.server(), mode()) :: :ok
  def mode(plane, mode), do: GenServer.call(plane, {:mode, mode})

  @doc "Answer in chunks from now on, or stop doing so."
  @spec chunked(GenServer.server(), boolean()) :: :ok
  def chunked(plane, chunked? \\ true),
    do: mode(plane, if(chunked?, do: :chunked, else: :content_length))

  @doc "Refuse connections, as a plane that is down does."
  @spec stop_listening(GenServer.server()) :: :ok
  def stop_listening(plane), do: GenServer.call(plane, :stop_listening)

  @doc "Listen again, on the port it had."
  @spec listen(GenServer.server()) :: :ok | {:error, term()}
  def listen(plane), do: GenServer.call(plane, :listen)

  ## The plane

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      port: 0,
      socket: nil,
      acceptor: nil,
      held: nil,
      requests: [],
      status: Keyword.get(opts, :status, 200),
      body: opts |> Keyword.get(:body, "") |> IO.iodata_to_binary(),
      answer: Keyword.get(opts, :answer),
      mode: Keyword.get(opts, :mode, :content_length)
    }

    case open(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}
  def handle_call(:clear, _from, state), do: {:reply, :ok, %{state | requests: []}}

  def handle_call({:respond_with, status, body}, _from, state),
    do: {:reply, :ok, %{state | status: status, body: body}}

  def handle_call({:answer, fun}, _from, state), do: {:reply, :ok, %{state | answer: fun}}

  def handle_call({:mode, mode}, _from, state), do: {:reply, :ok, %{state | mode: mode}}

  def handle_call(:stop_listening, _from, state), do: {:reply, :ok, shut(state)}

  def handle_call(:listen, _from, %{socket: nil} = state) do
    case open(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:listen, _from, state), do: {:reply, :ok, state}

  # A connection has been read. It is recorded before it is answered, so
  # whoever has the answer can ask for the request.
  def handle_call({:arrived, request}, _from, state) do
    {status, body} =
      case state.answer do
        nil ->
          {state.status, state.body}

        answer ->
          {status, body} = answer.(request)
          {status, IO.iodata_to_binary(body)}
      end

    {:reply, {status, body, state.mode}, %{state | requests: [request | state.requests]}}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state |> shut() |> release()
    :ok
  end

  defp open(state) do
    state = release(state)

    with {:ok, socket} <- :gen_tcp.listen(state.port, @listen),
         {:ok, port} <- :inet.port(socket) do
      plane = self()
      acceptor = spawn_link(fn -> accept(plane, socket) end)
      {:ok, %{state | socket: socket, port: port, acceptor: acceptor}}
    end
  end

  # Closing the socket is what ends the acceptor. It is waited for, so that
  # when this returns nothing is being accepted.
  defp shut(%{socket: nil} = state), do: state

  defp shut(%{socket: socket, acceptor: acceptor} = state) do
    ref = Process.monitor(acceptor)
    :gen_tcp.close(socket)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      1_000 -> Process.exit(acceptor, :kill)
    end

    %{state | socket: nil, acceptor: nil, held: hold(state.port)}
  end

  defp hold(port), do: bound(port, false) || bound(port, true)

  defp bound(port, shared?) do
    with {:ok, socket} <- :socket.open(:inet, :stream, :tcp) do
      with :ok <- :socket.setopt(socket, {:socket, :reuseaddr}, shared?),
           :ok <- :socket.bind(socket, %{family: :inet, port: port, addr: {127, 0, 0, 1}}) do
        socket
      else
        _ ->
          :socket.close(socket)
          nil
      end
    else
      _ -> nil
    end
  end

  defp release(%{held: nil} = state), do: state

  defp release(%{held: held} = state) do
    :socket.close(held)
    %{state | held: nil}
  end

  ## Connections

  defp accept(plane, listening) do
    case :gen_tcp.accept(listening) do
      {:ok, socket} ->
        handler = spawn(fn -> serve(plane) end)

        case :gen_tcp.controlling_process(socket, handler) do
          :ok -> send(handler, {:serve, socket})
          {:error, _} -> Process.exit(handler, :kill)
        end

        accept(plane, listening)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(plane) do
    # A connection does not outlive the plane it was made to.
    ref = Process.monitor(plane)

    receive do
      {:serve, socket} ->
        with {:ok, request} <- read(socket),
             {:ok, answer} <- arrived(plane, request) do
          answer(socket, answer, ref)
        end

        :gen_tcp.close(socket)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    end
  end

  defp arrived(plane, request) do
    {:ok, GenServer.call(plane, {:arrived, request})}
  catch
    :exit, _ -> :error
  end

  defp read(socket) do
    :ok = :inet.setopts(socket, packet: :http_bin)

    with {:ok, {:http_request, method, target, _version}} <- :gen_tcp.recv(socket, 0, 5_000),
         {:ok, headers} <- read_headers(socket, %{}),
         :ok <- :inet.setopts(socket, packet: :raw),
         {:ok, body} <- read_body(socket, headers) do
      {:ok, %{method: to_string(method), path: path(target), headers: headers, body: body}}
    end
  end

  defp read_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(socket, Map.put(headers, name |> to_string() |> String.downcase(), value))

      {:ok, :http_eoh} ->
        {:ok, headers}

      other ->
        {:error, other}
    end
  end

  defp read_body(socket, headers) do
    case String.to_integer(Map.get(headers, "content-length", "0")) do
      0 -> {:ok, ""}
      bytes -> :gen_tcp.recv(socket, bytes, 5_000)
    end
  end

  defp path({:abs_path, path}), do: path
  defp path({:absoluteURI, _scheme, _host, _port, path}), do: path
  defp path(other), do: inspect(other)

  defp answer(socket, {_status, _body, :hang}, ref) do
    # Held open until whoever asked gives up, or the plane ends.
    :ok = :inet.setopts(socket, active: true)

    receive do
      {:tcp_closed, ^socket} -> :ok
      {:tcp_error, ^socket, _reason} -> :ok
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end

  defp answer(socket, {status, body, {:drip, ms}}, ref) do
    [head(status), "content-length: #{byte_size(body)}\r\n\r\n", body]
    |> IO.iodata_to_binary()
    |> pieces(8)
    |> Enum.reduce_while(:ok, fn piece, :ok ->
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> {:halt, :ok}
      after
        ms ->
          case :gen_tcp.send(socket, piece) do
            :ok -> {:cont, :ok}
            {:error, _} -> {:halt, :ok}
          end
      end
    end)
  end

  defp answer(socket, {status, body, mode}, _ref) do
    answer =
      case mode do
        :content_length ->
          [head(status), "content-length: #{byte_size(body)}\r\n\r\n", body]

        :chunked ->
          chunks =
            for piece <- pieces(body, 7) do
              [Integer.to_string(byte_size(piece), 16), "\r\n", piece, "\r\n"]
            end

          [head(status), "transfer-encoding: chunked\r\n\r\n", chunks, "0\r\n\r\n"]

        :until_close ->
          [head(status), "\r\n", body]
      end

    with :ok <- :gen_tcp.send(socket, answer),
         :ok <- :gen_tcp.shutdown(socket, :write) do
      # Wait for the other end to have read it and closed.
      :gen_tcp.recv(socket, 0, 1_000)
    end
  end

  defp head(status) do
    ["HTTP/1.1 ", Integer.to_string(status), ?\s, reason(status), "\r\nconnection: close\r\n"]
  end

  defp reason(200), do: "OK"
  defp reason(204), do: "No Content"
  defp reason(401), do: "Unauthorized"
  defp reason(404), do: "Not Found"
  defp reason(500), do: "Internal Server Error"
  defp reason(503), do: "Service Unavailable"
  defp reason(_), do: "Status"

  defp pieces("", _bytes), do: []

  defp pieces(data, bytes) when byte_size(data) <= bytes, do: [data]

  defp pieces(data, bytes) do
    {piece, rest} = :erlang.split_binary(data, bytes)
    [piece | pieces(rest, bytes)]
  end
end
