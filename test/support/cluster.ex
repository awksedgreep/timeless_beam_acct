defmodule TimelessBeamAcct.Cluster do
  @moduledoc """
  Other nodes, for tests: started by the test, and stopped by it.

  The node that runs the tests is made a distributed one for as long as
  the tests that need it run, under a name and a cookie made up for the
  occasion, so that nothing else on the host is of its cluster.
  """

  @doc """
  Whether there is an epmd to be had. Known before the tests run, so that
  those that need one are skipped, and said to be.
  """
  def possible? do
    Node.alive?() or match?({:ok, _}, :erl_epmd.names()) or
      System.find_executable("epmd") != nil
  end

  @peers __MODULE__.Peers

  # The name of a node started for this test, which is stopped at the end
  # of it.
  def start_peer(cookie, opts \\ []) do
    # Unless told otherwise, a peer is told what to do over a connection
    # between the two nodes, and so is connected from the start.
    {:ok, pid, node} =
      %{
        name: :peer.random_name(~c"tba_peer"),
        args: [~c"-setcookie", Atom.to_charlist(cookie)],
        wait_boot: 30_000
      }
      |> Map.merge(Map.new(opts))
      |> :peer.start()

    Agent.update(@peers, &Map.put(&1, node, pid))
    ExUnit.Callbacks.on_exit(fn -> stop_peer(node) end)
    node
  end

  # Stopped, and known by this node to be gone.
  def stop_peer(node) do
    case Agent.get_and_update(@peers, &Map.pop(&1, node)) do
      nil ->
        :ok

      pid ->
        :net_kernel.monitor_nodes(true)
        connected? = node in Node.list(:connected)

        try do
          :peer.stop(pid)
        catch
          :exit, _ -> :ok
        end

        if connected? do
          receive do
            {:nodedown, ^node} -> :ok
          after
            5_000 -> :ok
          end
        end

        :net_kernel.monitor_nodes(false)
        :ok
    end
  end

  # Make this node a distributed one. Returns the cookie of the cluster
  # there then is, and what undoes it all.
  def distribute do
    {:ok, peers} = Agent.start(fn -> %{} end, name: @peers)

    stop_peers = fn ->
      for {_node, pid} <- Agent.get(peers, & &1) do
        try do
          :peer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      Agent.stop(peers)
    end

    if Node.alive?() do
      # Distributed by whoever ran the tests: theirs to undo.
      {:ok, Node.get_cookie(), stop_peers}
    else
      with :ok <- epmd() do
        cookie =
          :"tba_#{:erlang.phash2(make_ref())}_#{System.unique_integer([:positive])}_#{System.os_time()}"

        name = :"tba_test_#{System.pid()}_#{System.unique_integer([:positive])}"
        undo_home = borrow_a_cookie_file()

        try do
          case :net_kernel.start(name, %{name_domain: :shortnames}) do
            {:ok, _pid} ->
              Node.set_cookie(cookie)

              {:ok, cookie,
               fn ->
                 stop_peers.()
                 :net_kernel.stop()
               end}

            {:error, why} ->
              stop_peers.()
              {:error, "the node could not be distributed: #{inspect(why)}"}
          end
        after
          undo_home.()
        end
      else
        {:error, why} ->
          stop_peers.()
          {:error, why}
      end
    end
  end

  # A node that is distributed reads its cookie from a file in the home
  # directory, and writes the file if there is none. The cookie is set to
  # another as soon as the node is up, so the file is of no use here, and
  # a test has no business writing to a home directory: if there is no
  # file, the node is shown one in a directory of the build, which is
  # where it looks second.
  defp borrow_a_cookie_file do
    home =
      case :init.get_argument(:home) do
        {:ok, [[home | _] | _]} -> List.to_string(home)
        _ -> nil
      end

    config = :filename.basedir(:user_config, ~c"erlang") |> List.to_string()

    in_home? = home != nil and File.exists?(Path.join(home, ".erlang.cookie"))
    in_config? = File.exists?(Path.join(config, ".erlang.cookie"))

    if in_home? or in_config? do
      fn -> :ok end
    else
      was = System.get_env("XDG_CONFIG_HOME")
      borrowed = Path.join(Mix.Project.build_path(), "dist_test_#{System.pid()}")
      file = Path.join([borrowed, "erlang", ".erlang.cookie"])
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "not_the_cookie_of_any_cluster")
      File.chmod!(file, 0o400)
      System.put_env("XDG_CONFIG_HOME", borrowed)

      fn ->
        if was,
          do: System.put_env("XDG_CONFIG_HOME", was),
          else: System.delete_env("XDG_CONFIG_HOME")

        File.rm_rf!(borrowed)
        :ok
      end
    end
  end

  # epmd is what nodes on a host find each other by. One that is running
  # is used, and left running: other nodes may be registered with it.
  defp epmd do
    if epmd_answers?() do
      :ok
    else
      :os.cmd(~c"epmd -daemon")

      if Enum.any?(1..50, fn _ -> epmd_answers?() or (Process.sleep(100) && false) end),
        do: :ok,
        else: {:error, "epmd is not running, and could not be started"}
    end
  end

  defp epmd_answers?, do: match?({:ok, _}, :erl_epmd.names())
end
