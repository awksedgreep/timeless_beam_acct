defmodule TimelessBeamAcct.Remote do
  @moduledoc """
  A collector in a node that is already running.

  timeless-acct is started on a host and accounts for what is already
  running there. A node is accounted for from inside, by a collector that
  is one of its processes, and the node that needs accounting for is the
  one that is misbehaving now and was built last month without one.

  So a collector can be put into a running node from another: the
  collector's modules are sent to it and loaded, and a collector is
  started there. Nothing is installed and nothing is restarted. The
  collector has no dependencies, so that its modules are all that has to
  be sent.

      iex> TimelessBeamAcct.Remote.connect("app@ohm", cookie: "secret")
      {:ok, :app@ohm}
      iex> TimelessBeamAcct.Remote.attach(:app@ohm, sink: :http)
      {:ok, #PID<23456.812.0>}
      iex> TimelessBeamAcct.Remote.top(:app@ohm)
      iex> TimelessBeamAcct.Remote.detach(:app@ohm)
      :ok

  ## What the node has to be

  A node with Elixir in it, no older than the Elixir and the OTP these
  modules were compiled with: a module compiled for a newer VM is refused
  by an older one, and one compiled against a newer Elixir calls what an
  older one does not have.

  ## What stays behind

  The collector belongs to no supervisor of the node's, since the node has
  none that expects it. It is held by a process of its own, the guest,
  which is not linked to whoever attached it: the node that attached it
  can go, and the collector stays until it is detached or the node ends.

  Detaching stops the collector and takes the modules out again, if
  attaching was what put them in.
  """

  alias TimelessBeamAcct.{Options, Report}

  @timeout 30_000
  @loaded {__MODULE__, :loaded}

  @type reason :: String.t()

  ## Reaching a node

  @doc """
  Connect to a node, making this one a distributed node first if it is
  not one.

    * `:cookie`: the cookie of the node to reach
    * `:as`: the name this node takes, if it has to take one

  Whether names are short or long is decided by the name of the node to
  reach: a name with a dot in its host is a long one.
  """
  @spec connect(node() | String.t(), keyword()) :: {:ok, node()} | {:error, reason()}
  def connect(node, opts \\ [])

  def connect(node, opts) when is_binary(node), do: connect(String.to_atom(node), opts)

  def connect(node, opts) when is_atom(node) do
    with :ok <- named(node),
         :ok <- distributed(node, opts[:as]),
         :ok <- cookie(node, opts[:cookie]) do
      if Node.connect(node) == true,
        do: {:ok, node},
        else:
          {:error,
           "#{node} cannot be reached: it is not running, or is not of this cookie, " <>
             "or its host is not known by that name"}
    end
  end

  defp named(node) do
    case node |> Atom.to_string() |> String.split("@") do
      [name, host] when name != "" and host != "" -> :ok
      _ -> {:error, "#{inspect(node)} is not the name of a node: expected name@host"}
    end
  end

  defp distributed(node, as) do
    if Node.alive?() do
      :ok
    else
      [_, host] = node |> Atom.to_string() |> String.split("@")
      domain = if String.contains?(host, "."), do: :longnames, else: :shortnames
      name = as || :"timeless_beam_acct_#{System.pid()}"
      name = if is_binary(name), do: String.to_atom(name), else: name

      case start_distribution(name, domain) do
        {:ok, _pid} ->
          :ok

        {:error, why} ->
          {:error, "this node could not be made a distributed one: #{inspect(why, limit: 5)}"}
      end
    end
  end

  # Nodes on a host find each other by epmd, which a node started with a
  # name starts if it has to, and a node made distributed later does not.
  defp start_distribution(name, domain) do
    case :net_kernel.start(name, %{name_domain: domain}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, _why} = first ->
        with epmd when is_binary(epmd) <- System.find_executable("epmd"),
             {_, 0} <- System.cmd(epmd, ["-daemon"]) do
          Process.sleep(200)
          :net_kernel.start(name, %{name_domain: domain})
        else
          _ -> first
        end
    end
  end

  defp cookie(_node, nil), do: :ok

  defp cookie(node, cookie) when is_binary(cookie) and cookie != "",
    do: cookie(node, String.to_atom(cookie))

  defp cookie(node, cookie) when is_atom(cookie) do
    Node.set_cookie(node, cookie)
    :ok
  end

  defp cookie(_node, other), do: {:error, ":cookie is #{inspect(other)}: expected a cookie"}

  ## Attaching

  @doc """
  Put a collector into a node, and start it.

  The options are those of `TimelessBeamAcct.Options`. They are checked
  here, before anything is sent. `:host` and `:node`, if not given, are
  those of the node attached to, as they would be had it been started
  there.
  """
  @spec attach(node(), keyword()) :: {:ok, pid()} | {:error, reason()}
  def attach(node, opts \\ []) when is_atom(node) and is_list(opts) do
    with :ok <- checked(fn -> Options.new!(opts) end),
         :ok <- reached(node),
         :ok <- compatible(node),
         :ok <- load(node) do
      case call(node, __MODULE__, :start_guest, [opts]) do
        {:ok, {:ok, pid}} ->
          {:ok, pid}

        {:ok, {:error, reason}} ->
          unload(node)
          {:error, reason}

        {:error, reason} ->
          unload(node)
          {:error, reason}
      end
    end
  end

  @doc false
  @spec guests() :: [atom()]
  def guests do
    for name <- Process.registered(),
        String.ends_with?(Atom.to_string(name), ".Guest"),
        do: name
  end

  @doc """
  Stop the collector that was put into a node, and take out what was put
  in with it.
  """
  @spec detach(node(), atom()) :: :ok | {:error, reason()}
  def detach(node, name \\ TimelessBeamAcct) when is_atom(node) do
    with :ok <- reached(node),
         {:ok, :ok} <- call(node, __MODULE__, :stop_guest, [name]) do
      unload(node)
    else
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Whether a collector of this name was put into the node and is running."
  @spec attached?(node(), atom()) :: boolean()
  def attached?(node, name \\ TimelessBeamAcct) do
    match?(
      {:ok, pid} when is_pid(pid),
      call(node, Process, :whereis, [Options.name(name, :Guest)])
    )
  end

  defp checked(fun) do
    fun.()
    :ok
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp reached(node) do
    cond do
      node == node() -> {:error, "#{node} is this node: start a collector in it"}
      node in Node.list(:connected) -> :ok
      Node.connect(node) == true -> :ok
      true -> {:error, "#{node} is not connected: see TimelessBeamAcct.Remote.connect/2"}
    end
  end

  defp compatible(node) do
    ours = :erlang.system_info(:otp_release) |> List.to_integer()

    with {:ok, release} <- call(node, :erlang, :system_info, [:otp_release]),
         theirs = List.to_integer(release),
         {:otp, true} <- {:otp, theirs >= ours},
         {:ok, version} when is_binary(version) <- elixir(node),
         {:elixir, true} <- {:elixir, not older?(version, System.version())} do
      :ok
    else
      {:otp, false} ->
        {:ok, release} = call(node, :erlang, :system_info, [:otp_release])

        {:error,
         "#{node} runs OTP #{release}, and these modules were compiled with OTP #{ours}: " <>
           "compile them with the OTP the node runs"}

      {:elixir, false} ->
        {:ok, version} = elixir(node)

        {:error,
         "#{node} has Elixir #{version}, and these modules were compiled with " <>
           "Elixir #{System.version()}: compile them with the Elixir the node has"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp elixir(node) do
    case call(node, :code, :ensure_loaded, [System]) do
      {:ok, {:module, System}} -> call(node, System, :version, [])
      {:ok, _} -> {:error, "#{node} has no Elixir in it, and a collector is written in Elixir"}
      {:error, reason} -> {:error, reason}
    end
  end

  # By minor version: a patch release adds nothing that is called.
  defp older?(theirs, ours) do
    with {:ok, theirs} <- Version.parse(theirs), {:ok, ours} <- Version.parse(ours) do
      {theirs.major, theirs.minor} < {ours.major, ours.minor}
    else
      _ -> false
    end
  end

  ## The modules

  @doc """
  The modules of a collector: what is sent to a node.

  The tasks are not, nor what draws a node in a terminal or a dashboard:
  they run where they are typed, or where the dashboard is.
  """
  @spec modules() :: [module()]
  def modules do
    Application.load(:timeless_beam_acct)

    for module <- Application.spec(:timeless_beam_acct, :modules) || [],
        not match?("Elixir.Mix.Tasks." <> _, Atom.to_string(module)),
        not match?("Elixir.TimelessBeamAcct.Watch" <> _, Atom.to_string(module)),
        not match?("Elixir.TimelessBeamAcct.Dashboard" <> _, Atom.to_string(module)),
        do: module
  end

  defp load(node) do
    case call(node, :code, :is_loaded, [TimelessBeamAcct]) do
      # The node was built with a collector in it, or has been attached to
      # before. What it has is what it runs.
      {:ok, {:file, _}} ->
        :ok

      {:ok, false} ->
        case call(node, :code, :ensure_loaded, [TimelessBeamAcct]) do
          {:ok, {:module, _}} -> :ok
          {:ok, {:error, _}} -> send_modules(node)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_modules(node) do
    modules = modules()

    sent =
      Enum.reduce_while(modules, :ok, fn module, :ok ->
        with {^module, binary, file} <- :code.get_object_code(module),
             {:ok, {:module, ^module}} <- call(node, :code, :load_binary, [module, file, binary]) do
          {:cont, :ok}
        else
          :error -> {:halt, {:error, "the code of #{inspect(module)} is not to be found"}}
          {:ok, {:error, why}} -> {:halt, {:error, "#{node} refused #{inspect(module)}: #{why}"}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case sent do
      :ok ->
        call(node, :persistent_term, :put, [@loaded, modules])
        :ok

      {:error, reason} ->
        take_out(node, modules)
        {:error, reason}
    end
  end

  # Only what attaching put in is taken out, and only when the last
  # collector that was attached is gone: a node built with a collector in
  # it keeps it, and a collector that is running keeps its modules.
  defp unload(node) do
    with {:ok, []} <- call(node, __MODULE__, :guests, []),
         {:ok, [_ | _] = modules} <- call(node, :persistent_term, :get, [@loaded, []]) do
      take_out(node, modules)
      call(node, :persistent_term, :erase, [@loaded])
      :ok
    else
      _ -> :ok
    end
  end

  defp take_out(node, modules) do
    for module <- modules do
      call(node, :code, :delete, [module])
      call(node, :code, :purge, [module])
    end

    :ok
  end

  defp call(node, module, function, args) do
    {:ok, :erpc.call(node, module, function, args, @timeout)}
  catch
    :error, {:erpc, reason} ->
      {:error, "#{node} could not be asked: #{inspect(reason)}"}

    :error, {:exception, reason, _stack} ->
      {:error, "#{node} could not do it: #{inspect(reason, limit: 5)}"}

    kind, reason ->
      {:error, "#{node} could not do it: #{kind} #{inspect(reason, limit: 5)}"}
  end

  ## In the node attached to

  @doc false
  @spec start_guest(keyword()) :: {:ok, pid()} | {:error, reason()}
  def start_guest(opts) do
    options = Options.new!(opts)
    name = Options.name(options, :Guest)

    cond do
      Process.whereis(name) ->
        {:error, "a collector named #{inspect(options.name)} is attached to #{node()} already"}

      TimelessBeamAcct.running?(options.name) ->
        {:error, "a collector named #{inspect(options.name)} is running in #{node()} already"}

      true ->
        asked = self()
        ref = make_ref()
        guest = spawn(fn -> guest(options, name, asked, ref) end)
        monitor = Process.monitor(guest)

        receive do
          {^ref, result} ->
            Process.demonitor(monitor, [:flush])
            result

          {:DOWN, ^monitor, _, _, reason} ->
            {:error, "the collector could not be started: #{inspect(reason, limit: 5)}"}
        after
          @timeout -> {:error, "the collector did not start in time"}
        end
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  @doc false
  @spec stop_guest(atom()) :: :ok | {:error, reason()}
  def stop_guest(name) do
    case Process.whereis(Options.name(name, :Guest)) do
      nil ->
        {:error, "no collector named #{inspect(name)} is attached to #{node()}"}

      guest ->
        monitor = Process.monitor(guest)
        send(guest, :detach)

        receive do
          {:DOWN, ^monitor, _, _, _} -> :ok
        after
          @timeout -> {:error, "the collector did not stop in time"}
        end
    end
  end

  defp guest(options, name, asked, ref) do
    Process.register(self(), name)
    Process.flag(:trap_exit, true)

    # What the collector says, it says where the node says things, and
    # not to the node that attached it, which may be gone by then.
    if user = Process.whereis(:user), do: Process.group_leader(self(), user)

    started =
      try do
        TimelessBeamAcct.start_link(options)
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case started do
      {:ok, collector} ->
        send(asked, {ref, {:ok, collector}})
        host(collector)

      {:error, reason} ->
        send(asked, {ref, {:error, "the collector could not be started: #{why(reason)}"}})
    end
  end

  defp why({:shutdown, {:failed_to_start_child, _, {:sink, reason}}}) when is_binary(reason),
    do: reason

  defp why({:shutdown, {:failed_to_start_child, _, {:sink, reason}}}),
    do: "the sink could not be made: #{inspect(reason, limit: 5)}"

  defp why(reason), do: inspect(reason, limit: 5)

  defp host(collector) do
    receive do
      :detach ->
        Supervisor.stop(collector, :normal, @timeout)

      {:EXIT, ^collector, _reason} ->
        :ok

      _other ->
        host(collector)
    end
  catch
    :exit, _ -> :ok
  end

  ## Looking, from another node

  @doc "Print the processes of a node that are doing the most. See `TimelessBeamAcct.top/1`."
  @spec top(node(), keyword()) :: :ok | {:error, reason()}
  def top(node, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, TimelessBeamAcct)
    printed(node, :snapshot, [name], &Report.top(&1, opts))
  end

  @doc "Print the processes of a node that ended. See `TimelessBeamAcct.exits/1`."
  @spec exits(node(), keyword()) :: :ok | {:error, reason()}
  def exits(node, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, TimelessBeamAcct)
    {summary, opts} = Keyword.pop(opts, :summary, false)

    # Every record is asked for, and chosen from here: a time that is
    # written is a time where it is written.
    printed(node, :records, [[name: name, kind: :any]], fn records ->
      if summary,
        do: Report.summary(records, opts),
        else: Report.exits(records, Keyword.delete(opts, :by))
    end)
  end

  @doc "Print the jobs of a node, as trees. See `TimelessBeamAcct.trees/1`."
  @spec trees(node(), keyword()) :: :ok | {:error, reason()}
  def trees(node, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, TimelessBeamAcct)
    printed(node, :spans, [name], &Report.trees(&1, opts))
  end

  @doc "Print what a node lets a collector see. See `TimelessBeamAcct.check/1`."
  @spec check(node(), keyword()) :: :ok | {:error, reason()}
  def check(node, opts \\ []) do
    with :ok <- reached(node),
         :ok <- compatible(node),
         {:ok, {:file, _}} <- call(node, :code, :is_loaded, [TimelessBeamAcct]) do
      printed(node, :checked, [opts], fn lines ->
        width = lines |> Enum.map(fn {what, _} -> String.length(what) end) |> Enum.max()

        Enum.map_join(lines, fn
          {"", ""} -> "\n"
          {what, how} -> String.pad_trailing(what, width + 3) <> how <> "\n"
        end)
      end)
    else
      {:ok, false} ->
        IO.puts("#{node} can have a collector put into it, and has none.")

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Print what a report of a problem should have in it. See `TimelessBeamAcct.diagnostics/1`."
  @spec diagnostics(node(), keyword()) :: :ok | {:error, reason()}
  def diagnostics(node, opts \\ []), do: printed(node, :diagnosed, [opts], & &1)

  @doc "Make a recording in a node run longer. See `TimelessBeamAcct.extend/2`."
  @spec extend(node(), String.t() | number(), atom()) :: {:ok, float()} | {:error, reason()}
  def extend(node, more, name \\ TimelessBeamAcct) do
    with :ok <- reached(node),
         {:ok, answer} <- call(node, TimelessBeamAcct, :extend, [name, more]),
         do: answer
  end

  @doc "What the collector in a node has to say of itself. See `TimelessBeamAcct.status/1`."
  @spec status(node(), atom()) :: {:ok, map() | nil} | {:error, reason()}
  def status(node, name \\ TimelessBeamAcct) do
    with :ok <- reached(node), do: call(node, TimelessBeamAcct, :status, [name])
  end

  defp printed(node, function, args, render) do
    with :ok <- reached(node),
         {:ok, answer} <- call(node, TimelessBeamAcct, function, args) do
      answer |> render.() |> IO.write()
    end
  end
end
