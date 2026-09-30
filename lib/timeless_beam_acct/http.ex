defmodule TimelessBeamAcct.Http do
  @moduledoc """
  An HTTP client for exactly what a collector needs: one request, one
  answer, and the connection closed.

  It is written on `:gen_tcp` and `:ssl` because this package has no
  dependencies and is meant to be loadable into a node that was built
  without it. `:httpc` is not used: it is part of inets, which a release
  need not include, and it is a service that has to be started and
  configured, where a collector wants a function that returns.

  There is no pool and no connection kept open. A collector posts three
  bodies every ten seconds, mostly to the host it runs on, and a
  connection that is opened for each has no state to go wrong while a
  plane is restarted.

  ## Time

  `timeout_ms` bounds the whole request: connecting, sending, and reading
  the answer. A deadline is worked out at the start and each step is given
  what is left, so a plane that answers one byte at a time cannot hold the
  writer for longer than it was told to wait.

  ## The answer

  A status outside 200..299 is an answer and not an error: the caller
  decides what it means. To a collector the body is only ever shown to a
  person, in a message, so 64 KiB of it is kept. Reading stops
  there, since nothing past it would be used and the request was answered
  when the status was sent. Whoever asks a plane a question and wants all
  of the answer says how much it may be, with `:keep`.

  ## TLS

  An `https` URL starts the `:ssl` application when it is first asked for,
  and is `{:error, :ssl_unavailable}` in a node that does not have it. The
  peer is verified against the trust store of the operating system, with
  its name checked against the certificate. `:cacerts` may be given to
  trust something else, which is what a plane with a certificate from a
  private authority needs.
  """

  # Neither is an application this one depends on: they are asked for only
  # by an https URL.
  @compile {:no_warn_undefined, [:ssl, :public_key]}

  @version Mix.Project.config()[:version]
  @user_agent "timeless-beam-acct/#{@version}"

  # How much of a body is kept, and the most asked of the socket at once.
  @keep 64 * 1024
  @piece 64 * 1024
  @max_headers 200

  @type header :: {String.t(), String.t()}
  @type reason ::
          :timeout
          | :closed
          | :ssl_unavailable
          | :no_trust_store
          | {:bad_url, term()}
          | {:bad_header, term()}
          | {:bad_response, String.t()}
          | {:tls_alert, term()}
          | atom()
          | term()
  @type result :: {:ok, status :: 100..999, body :: binary()} | {:error, reason()}
  @type option :: {:cacerts, [binary()]} | {:keep, pos_integer()}

  @doc """
  Send `body` to `url`, and return what was answered.

  `headers` are sent after `Host`, `Content-Length`, `Connection: close`,
  and `User-Agent`. `timeout_ms` is for the whole request.
  """
  @spec post(String.t(), iodata(), [header()], non_neg_integer(), [option()]) :: result()
  def post(url, body, headers, timeout_ms, opts \\ []) do
    request("POST", url, body, headers, timeout_ms, opts)
  end

  @doc """
  Ask for `url`, and return what was answered. For finding out whether
  something is there.
  """
  @spec get(String.t(), [header()], non_neg_integer(), [option()]) :: result()
  def get(url, headers, timeout_ms, opts \\ []) do
    request("GET", url, nil, headers, timeout_ms, opts)
  end

  @doc """
  A reason, in words.
  """
  @spec format_error(reason()) :: String.t()
  def format_error(:timeout), do: "timed out"
  def format_error(:closed), do: "the connection was closed before the answer was complete"

  def format_error(:ssl_unavailable),
    do: "https was asked for and the ssl application is not available in this node"

  def format_error(:no_trust_store),
    do: "the certificates this system trusts could not be read"

  def format_error({:bad_url, url}), do: "#{inspect(url)} is not an http or https URL"

  def format_error({:bad_header, header}),
    do: "#{inspect(header)} cannot be sent as a header"

  def format_error({:bad_response, what}), do: "what answered is not HTTP: #{what}"

  def format_error({:tls_alert, {_kind, text}}) when is_list(text) or is_binary(text),
    do: text |> to_string() |> one_line()

  def format_error({:options, option}),
    do: "TLS was given an option it refuses: #{inspect(option)}"

  def format_error(reason) when is_atom(reason) do
    case reason |> :inet.format_error() |> to_string() do
      "unknown POSIX error" <> _ -> Atom.to_string(reason)
      words -> words
    end
  end

  def format_error(reason), do: inspect(reason)

  defp one_line(text), do: text |> String.split() |> Enum.join(" ")

  ## The request

  defp request(method, url, body, headers, timeout_ms, opts)
       when is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = now() + timeout_ms

    with {:ok, target} <- parse(url),
         :ok <- check(headers),
         {:ok, socket} <- connect(target, deadline, opts) do
      try do
        with :ok <- send_request(socket, method, target, body, headers, deadline),
             {:ok, status, answered} <- read_head(socket, deadline) do
          read_body(socket, status, answered, deadline, kept(opts))
        end
      after
        close(socket)
      end
    end
  end

  # How much of a body is kept.
  defp kept(opts) do
    case Keyword.get(opts, :keep) do
      bytes when is_integer(bytes) and bytes > 0 -> bytes
      _ -> @keep
    end
  end

  defp parse(url) when is_binary(url) do
    with {:ok, %URI{scheme: scheme, host: host, port: port} = uri}
         when scheme in ["http", "https"] and is_binary(host) and host != "" and is_integer(port) <-
           URI.new(url) do
      path =
        case {uri.path, uri.query} do
          {path, nil} -> path || "/"
          {path, query} -> [path || "/", ??, query]
        end

      {:ok, %{scheme: scheme, host: host, port: port, path: path}}
    else
      _ -> {:error, {:bad_url, url}}
    end
  end

  defp parse(url), do: {:error, {:bad_url, url}}

  # A header with a line ending in it would be two headers, or a body.
  defp check(headers) when is_list(headers) do
    Enum.find_value(headers, :ok, fn
      {name, value} when is_binary(name) and is_binary(value) and name != "" ->
        if breaks?(name) or breaks?(value) or String.contains?(name, [":", " "]),
          do: {:error, {:bad_header, name}}

      other ->
        {:error, {:bad_header, other}}
    end)
  end

  defp check(headers), do: {:error, {:bad_header, headers}}

  defp breaks?(text), do: String.contains?(text, ["\r", "\n", <<0>>])

  defp send_request(socket, method, target, body, headers, deadline) do
    length =
      case body do
        nil -> []
        body -> ["Content-Length: ", Integer.to_string(IO.iodata_length(body)), "\r\n"]
      end

    request = [
      [method, ?\s, target.path, " HTTP/1.1\r\n"],
      ["Host: ", host_header(target), "\r\n"],
      length,
      "Connection: close\r\n",
      ["User-Agent: ", @user_agent, "\r\n"],
      for({name, value} <- headers, do: [name, ": ", value, "\r\n"]),
      "\r\n",
      body || []
    ]

    with {:ok, left} <- left(deadline),
         :ok <- setopts(socket, send_timeout: left) do
      send_all(socket, request)
    end
  end

  defp host_header(%{scheme: scheme, host: host, port: port}) do
    host = if String.contains?(host, ":"), do: [?[, host, ?]], else: host

    if port == URI.default_port(scheme),
      do: host,
      else: [host, ?:, Integer.to_string(port)]
  end

  ## The answer

  defp read_head(socket, deadline) do
    with :ok <- setopts(socket, packet: :http_bin),
         {:ok, line} <- recv(socket, 0, deadline) do
      case line do
        {:http_response, _version, status, _reason} ->
          with {:ok, headers} <- read_headers(socket, deadline, [], 0) do
            # 100 Continue and its kind come before the answer, and are
            # not it.
            if status in 100..199 and status != 101,
              do: read_head(socket, deadline),
              else: {:ok, status, headers}
          end

        {:http_error, text} ->
          {:error, {:bad_response, printable(text)}}

        other ->
          {:error, {:bad_response, inspect(other)}}
      end
    end
  end

  defp read_headers(_socket, _deadline, _headers, count) when count > @max_headers,
    do: {:error, {:bad_response, "more than #{@max_headers} headers"}}

  defp read_headers(socket, deadline, headers, count) do
    case recv(socket, 0, deadline) do
      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(socket, deadline, [{header_name(name), value} | headers], count + 1)

      {:ok, :http_eoh} ->
        {:ok, headers}

      {:ok, {:http_error, text}} ->
        {:error, {:bad_response, printable(text)}}

      {:ok, other} ->
        {:error, {:bad_response, inspect(other)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The socket gives the headers it knows as atoms.
  defp header_name(name) when is_atom(name), do: name |> Atom.to_string() |> String.downcase()
  defp header_name(name) when is_binary(name), do: String.downcase(name)

  defp read_body(_socket, status, _headers, _deadline, _keep) when status in [204, 304],
    do: {:ok, status, ""}

  defp read_body(socket, status, headers, deadline, keep) do
    read =
      cond do
        chunked?(headers) ->
          read_chunks(socket, deadline, [], 0, keep)

        length = List.keyfind(headers, "content-length", 0) ->
          case Integer.parse(String.trim(elem(length, 1))) do
            {bytes, ""} when bytes >= 0 ->
              with :ok <- setopts(socket, packet: :raw) do
                read_exactly(socket, bytes, deadline, [], 0, keep)
              end

            _ ->
              {:error, {:bad_response, "a content-length of #{printable(elem(length, 1))}"}}
          end

        true ->
          with :ok <- setopts(socket, packet: :raw) do
            read_to_close(socket, deadline, [], 0, keep)
          end
      end

    with {:ok, kept, _size} <- read do
      {:ok, status, kept |> Enum.reverse() |> IO.iodata_to_binary() |> clip(keep)}
    end
  end

  defp chunked?(headers) do
    Enum.any?(headers, fn {name, value} ->
      name == "transfer-encoding" and String.contains?(String.downcase(value), "chunked")
    end)
  end

  defp clip(body, keep) when byte_size(body) > keep, do: binary_part(body, 0, keep)
  defp clip(body, _keep), do: body

  # `kept` is newest first, and `size` is how much is in it.
  defp read_exactly(_socket, 0, _deadline, kept, size, _keep), do: {:ok, kept, size}

  defp read_exactly(_socket, _bytes, _deadline, kept, size, keep) when size >= keep,
    do: {:ok, kept, size}

  defp read_exactly(socket, bytes, deadline, kept, size, keep) do
    with {:ok, data} <- recv(socket, min(bytes, @piece), deadline) do
      read_exactly(
        socket,
        bytes - byte_size(data),
        deadline,
        [data | kept],
        size + byte_size(data),
        keep
      )
    end
  end

  defp read_to_close(_socket, _deadline, kept, size, keep) when size >= keep,
    do: {:ok, kept, size}

  defp read_to_close(socket, deadline, kept, size, keep) do
    case recv(socket, 0, deadline) do
      {:ok, data} -> read_to_close(socket, deadline, [data | kept], size + byte_size(data), keep)
      {:error, :closed} -> {:ok, kept, size}
      {:error, reason} -> {:error, reason}
    end
  end

  # Each chunk is its size in hexadecimal on a line, the bytes, and a line
  # ending. The socket is asked for a line, then for bytes, in turn.
  defp read_chunks(_socket, _deadline, kept, size, keep) when size >= keep,
    do: {:ok, kept, size}

  defp read_chunks(socket, deadline, kept, size, keep) do
    with :ok <- setopts(socket, packet: :line),
         {:ok, line} <- recv(socket, 0, deadline),
         {:ok, bytes} <- chunk_size(line) do
      if bytes == 0 do
        # Whatever trails the last chunk is not part of the body.
        {:ok, kept, size}
      else
        with :ok <- setopts(socket, packet: :raw),
             {:ok, kept, size} <- read_exactly(socket, bytes, deadline, kept, size, keep),
             :ok <- end_of_chunk(socket, deadline, size, keep) do
          read_chunks(socket, deadline, kept, size, keep)
        end
      end
    end
  end

  defp chunk_size(line) do
    case Integer.parse(String.trim_leading(line), 16) do
      {bytes, rest} when bytes >= 0 ->
        if String.trim(rest) == "" or String.starts_with?(String.trim_leading(rest), ";"),
          do: {:ok, bytes},
          else: {:error, {:bad_response, "a chunk of size #{printable(line)}"}}

      :error ->
        {:error, {:bad_response, "a chunk of size #{printable(line)}"}}
    end
  end

  # Reading stopped inside the chunk if enough has been kept.
  defp end_of_chunk(_socket, _deadline, size, keep) when size >= keep, do: :ok

  defp end_of_chunk(socket, deadline, _size, _keep) do
    with :ok <- setopts(socket, packet: :line),
         {:ok, line} <- recv(socket, 0, deadline) do
      if String.trim(line) == "",
        do: :ok,
        else: {:error, {:bad_response, "a chunk longer than it said it was"}}
    end
  end

  defp printable(text) when is_binary(text) do
    text = text |> String.replace_invalid() |> String.trim() |> String.slice(0, 80)
    if String.printable?(text), do: inspect(text), else: inspect(text, binaries: :as_binaries)
  end

  defp printable(other), do: inspect(other)

  ## The socket

  @tcp [:binary, active: false, packet: :raw, nodelay: true, send_timeout_close: true]

  defp connect(%{scheme: "http"} = target, deadline, _opts) do
    connect_to(target.host, deadline, fn address, family, left ->
      :gen_tcp.connect(address, target.port, @tcp ++ family, left)
    end)
    |> opened(:gen_tcp)
  end

  defp connect(%{scheme: "https"} = target, deadline, opts) do
    with :ok <- start_ssl(),
         {:ok, cacerts} <- cacerts(opts) do
      verify = [
        # Why a connection was refused is returned, to be said once by
        # whoever asked. It is not also logged.
        log_level: :none,
        verify: :verify_peer,
        cacerts: cacerts,
        depth: 8,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]

      connect_to(target.host, deadline, fn address, family, left ->
        # A name is sent so that a server of several can pick its
        # certificate. An address is not a name, and is checked against
        # the certificate as an address.
        named =
          if is_list(address),
            do: [server_name_indication: address],
            else: []

        guarded(fn ->
          :ssl.connect(address, target.port, @tcp ++ family ++ verify ++ named, left)
        end)
      end)
      |> opened(:ssl)
    end
  end

  defp opened({:ok, socket}, transport), do: {:ok, {transport, socket}}
  defp opened({:error, reason}, _transport), do: {:error, reason}
  defp opened(other, _transport), do: {:error, other}

  # An address is connected to as the family it is. A name is looked up as
  # IPv4, and as IPv6 if it has no address there.
  defp connect_to(host, deadline, connect) do
    name = String.to_charlist(host)

    case :inet.parse_address(name) do
      {:ok, address} when tuple_size(address) == 8 ->
        within(deadline, &connect.(address, [:inet6], &1))

      {:ok, address} ->
        within(deadline, &connect.(address, [:inet], &1))

      {:error, _} ->
        case within(deadline, &connect.(name, [:inet], &1)) do
          {:error, :nxdomain} -> within(deadline, &connect.(name, [:inet6], &1))
          other -> other
        end
    end
  end

  defp within(deadline, step) do
    with {:ok, left} <- left(deadline), do: step.(left)
  end

  # The application being started is not enough: under Mix it may be, by
  # Mix, in a project whose code path does not have it.
  defp start_ssl do
    with true <- Code.ensure_loaded?(:ssl),
         true <- Code.ensure_loaded?(:public_key),
         {:ok, _started} <- guarded(fn -> Application.ensure_all_started(:ssl) end) do
      :ok
    else
      _ -> {:error, :ssl_unavailable}
    end
  end

  defp cacerts(opts) do
    case Keyword.fetch(opts, :cacerts) do
      {:ok, cacerts} when is_list(cacerts) ->
        {:ok, cacerts}

      {:ok, other} ->
        {:error, {:options, {:cacerts, other}}}

      :error ->
        case guarded(fn -> :public_key.cacerts_get() end) do
          [_ | _] = cacerts -> {:ok, cacerts}
          _ -> {:error, :no_trust_store}
        end
    end
  end

  # What is asked of ssl and public_key raises where a function of
  # gen_tcp's would return: for a trust store that is not there, or a node
  # without the application.
  defp guarded(step) do
    step.()
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exited, reason}}
    thrown -> {:error, {:thrown, thrown}}
  end

  defp recv({transport, socket}, bytes, deadline) do
    with {:ok, left} <- left(deadline), do: transport.recv(socket, bytes, left)
  end

  defp send_all({transport, socket}, data), do: transport.send(socket, data)

  defp setopts({:gen_tcp, socket}, options), do: :inet.setopts(socket, options)
  defp setopts({:ssl, socket}, options), do: :ssl.setopts(socket, options)

  defp close({transport, socket}) do
    guarded(fn -> transport.close(socket) end)
    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)

  # What is left of the time given, or that there is none.
  defp left(deadline) do
    case deadline - now() do
      left when left > 0 -> {:ok, left}
      _ -> {:error, :timeout}
    end
  end
end
