defmodule TimelessBeamAcct.RealPlanes do
  @moduledoc """
  Where the planes are that `test/planes_test.exs` writes to, and whether
  it may.

  That test writes to servers that are running, and what it writes stays
  in them. The planes of a developer's machine are where the sink sends
  when it is told nothing, on ports 8428, 9428, and 10428, and they hold
  what the developer's own nodes have recorded. A test must never write
  there. So the planes are named, each by a variable of the environment,
  and a test that was not told of all three does not guess:

  | variable | is the URL of |
  |---|---|
  | `TIMELESS_TEST_METRICS_URL` | the metrics plane |
  | `TIMELESS_TEST_LOGS_URL` | the logs plane |
  | `TIMELESS_TEST_TRACES_URL` | the traces plane |

  A URL is refused if its port is one of those three and its host is this
  machine: a loopback address, `localhost`, an address that accepts from
  any, or an address of one of this machine's interfaces. It is refused
  by what it says, before anything is sent to it.

  Planes started with authentication required take a token each, from
  `TIMELESS_TEST_METRICS_TOKEN`, `TIMELESS_TEST_LOGS_TOKEN`, and
  `TIMELESS_TEST_TRACES_TOKEN`. The tokens must allow reading as well as
  writing.
  """

  @planes [:metrics, :logs, :traces]
  @kept_for_the_developer [8428, 9428, 10428]

  @type plane :: :metrics | :logs | :traces

  @doc "The variable that names a plane's URL."
  @spec url_variable(plane()) :: String.t()
  def url_variable(plane) when plane in @planes,
    do: "TIMELESS_TEST_#{plane |> Atom.to_string() |> String.upcase()}_URL"

  @doc "The variable that names a plane's token."
  @spec token_variable(plane()) :: String.t()
  def token_variable(plane) when plane in @planes,
    do: "TIMELESS_TEST_#{plane |> Atom.to_string() |> String.upcase()}_TOKEN"

  @doc """
  The options of a sink that writes to the planes the environment names,
  or why there is to be no such sink.

  `env` is the environment, as `System.get_env/0` returns it.
  """
  @spec sink_options(%{String.t() => String.t()}) :: {:ok, keyword()} | {:error, String.t()}
  def sink_options(env \\ System.get_env()) when is_map(env) do
    Enum.reduce_while(@planes, {:ok, []}, fn plane, {:ok, options} ->
      variable = url_variable(plane)

      case allowed(variable, Map.get(env, variable)) do
        {:ok, url} ->
          token =
            case Map.get(env, token_variable(plane)) do
              empty when empty in [nil, ""] -> []
              token -> [{:"#{plane}_token", token}]
            end

          {:cont, {:ok, options ++ [{:"#{plane}_url", url}] ++ token}}

        {:error, why} ->
          {:halt, {:error, why}}
      end
    end)
  end

  defp allowed(variable, unset) when unset in [nil, ""] do
    {:error,
     "#{variable} is not set. This test writes to planes that are running, and is " <>
       "told where each of the three is: it does not write to the planes of this machine"}
  end

  defp allowed(variable, url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and is_integer(port) ->
        if port in @kept_for_the_developer and here?(host) do
          {:error,
           "#{variable} is #{url}: port #{port} of this machine is where the planes " <>
             "of whoever works on it are, and a test does not write to those"}
        else
          {:ok, String.trim_trailing(url, "/")}
        end

      _ ->
        {:error, "#{variable} is #{inspect(url)}: expected an http or https URL"}
    end
  end

  @doc """
  Whether a host is this machine, as far as can be told without asking
  anything of it.
  """
  @spec here?(String.t()) :: boolean()
  def here?(host) when is_binary(host) do
    name = host |> String.trim_leading("[") |> String.trim_trailing("]") |> String.downcase()

    case :inet.parse_address(String.to_charlist(name)) do
      {:ok, address} ->
        of_this_machine?(address)

      {:error, _} ->
        name == "localhost" or String.ends_with?(name, ".localhost") or
          name == hostname() or Enum.any?(addresses(name), &of_this_machine?/1)
    end
  end

  defp of_this_machine?({127, _, _, _}), do: true
  defp of_this_machine?({0, 0, 0, 0}), do: true
  defp of_this_machine?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp of_this_machine?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # An IPv4 address written as an IPv6 one.
  defp of_this_machine?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: of_this_machine?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})

  defp of_this_machine?(address), do: address in interfaces()

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> name |> List.to_string() |> String.downcase()
      _ -> nil
    end
  end

  # What the name is known as here. A name that is not known is no
  # address, and nothing can be sent to it either.
  defp addresses(name) do
    for family <- [:inet, :inet6],
        {:ok, addresses} <- [:inet.getaddrs(String.to_charlist(name), family)],
        address <- addresses,
        do: address
  end

  defp interfaces do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        for {_name, options} <- interfaces, {:addr, address} <- options, do: address

      _ ->
        []
    end
  end
end
