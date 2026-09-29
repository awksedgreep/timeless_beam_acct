defmodule TimelessBeamAcct.IdentityTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.Identity

  defmodule Server do
    use GenServer
    def init(arg), do: {:ok, arg}
  end

  describe "from what a process was started with" do
    test "a server is its callback module" do
      spawned =
        {:proc_lib, :init_p,
         [self(), [], :gen, :init_it, [:gen_server, self(), :self, Server, :arg, []]]}

      identity = Identity.of_spawn(spawned)
      assert identity.call == {Server, :init, 1}
      assert identity.name == nil
      assert Identity.group(identity) == "TimelessBeamAcct.IdentityTest.Server"
      assert Identity.path(identity) == "TimelessBeamAcct.IdentityTest.Server.init/1"
    end

    test "a server started under a name has it before it has registered it" do
      spawned =
        {:proc_lib, :init_p,
         [
           self(),
           [],
           :gen,
           :init_it,
           [:gen_server, self(), :self, {:local, :the_server}, Server, :arg, []]
         ]}

      identity = Identity.of_spawn(spawned)
      assert identity.call == {Server, :init, 1}
      assert identity.name == :the_server
      assert Identity.group(identity) == "the_server"
    end

    test "a supervisor is one, whichever way it was started" do
      plain =
        {:proc_lib, :init_p,
         [
           self(),
           [],
           :gen,
           :init_it,
           [
             :gen_server,
             self(),
             self(),
             :supervisor,
             {:self, Supervisor.Default, {:ok, {%{}, []}}},
             []
           ]
         ]}

      dynamic =
        {:proc_lib, :init_p,
         [
           self(),
           [],
           :gen,
           :init_it,
           [
             :gen_server,
             self(),
             self(),
             {:local, MySup},
             DynamicSupervisor,
             {Task.Supervisor, {{:temporary, 5000}, []}, MySup},
             []
           ]
         ]}

      assert Identity.of_spawn(plain).call == {:supervisor, Supervisor.Default, 1}
      assert Identity.starter?(Identity.of_spawn(plain))
      assert Identity.of_spawn(dynamic).call == {:supervisor, Task.Supervisor, 1}
      assert Identity.starter?(Identity.of_spawn(dynamic))
      assert Identity.path(Identity.of_spawn(dynamic)) == "Task.Supervisor.init/1"
      refute Identity.starter?(Identity.of_spawn({Kernel, :exit, [:x]}))
    end

    test "a module may be named as one whose processes start jobs" do
      identity = Identity.of_spawn({:my_acceptor, :loop, [1, 2]})
      refute Identity.starter?(identity)
      assert Identity.starter?(identity, [:my_acceptor])
    end

    test "a process spawned with a function is that function" do
      fun = fn -> :ok end
      identity = Identity.of_spawn({:erlang, :apply, [fun, []]})
      assert {TimelessBeamAcct.IdentityTest, name, 0} = identity.call
      assert Atom.to_string(name) =~ "fun"
      assert Identity.group(identity) =~ ~r/\Afn in TimelessBeamAcct\.IdentityTest\."?test /

      assert Identity.of_spawn({:proc_lib, :init_p, [self(), [], fun]}).call == identity.call
    end

    test "a process spawned with a module, a function, and arguments is that call" do
      identity = Identity.of_spawn({Kernel, :exit, [:custom]})
      assert identity.call == {Kernel, :exit, 1}
      assert Identity.group(identity) == "Kernel.exit/1"
      assert Identity.path(identity) == "Kernel.exit/1"

      assert Identity.group(Identity.of_spawn({:erts_code_purger, :start, []})) ==
               "erts_code_purger.start/0"
    end

    test "a task is started on behalf of its owner" do
      owner = self()
      replied = {Task.Supervised, :reply, [{node(), owner, owner}, [owner], :nomonitor]}
      identity = Identity.of_spawn(replied)
      assert identity.caller == owner
      # Its function is sent to it afterwards.
      assert identity.call == {Task.Supervised, :reply, 3}
    end

    test "a task that is not replied to is started with its function" do
      owner = self()

      unreplied =
        {Task.Supervised, :noreply,
         [{node(), owner, owner}, [owner], [owner], {Enum, :count, [[1]]}]}

      assert Identity.of_spawn(unreplied).call == {Enum, :count, 1}
    end

    test "a process started from another node is what that node said it was to run" do
      identity =
        Identity.of_spawn({:erts_internal, :dist_spawn_init, [{:erpc, :execute_call, 4}]})

      assert identity.call == {:erpc, :execute_call, 4}
      assert Identity.group(identity) == "erpc.execute_call/4"
    end

    test "what is not understood is unknown, and does not raise" do
      assert Identity.group(Identity.of_spawn(:what)) == "unknown"
      assert Identity.path(Identity.of_spawn({1, 2, 3})) == nil
    end
  end

  describe "from asking a process" do
    test "a registered server says its name and its callback module" do
      name = :"identity_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(Server, :arg, name: name)
      identity = Identity.read(pid)
      assert identity.name == name
      assert identity.call == {Server, :init, 1}
      assert identity.parent == self()
      assert is_pid(identity.group_leader)
      assert Identity.name(identity) == Atom.to_string(name)
    end

    test "a task says its function, and whom it is for" do
      task = Task.async(fn -> receive(do: (:stop -> :ok)) end)
      # It says so itself, once it is running.
      wait_until(fn -> Identity.read(task.pid).caller != nil end)
      identity = Identity.read(task.pid)
      assert identity.caller == self()
      assert {TimelessBeamAcct.IdentityTest, _, 0} = identity.call
      assert Identity.group(identity) =~ "fn in TimelessBeamAcct.IdentityTest."
      send(task.pid, :stop)
      Task.await(task)
    end

    test "a process spawned with a function is known by the bottom of its stack" do
      pid = spawn_link(fn -> receive(do: (:stop -> :ok)) end)
      identity = Identity.read(pid)
      assert {TimelessBeamAcct.IdentityTest, _, _} = identity.call
      send(pid, :stop)
    end

    test "what it was spawned with is kept where asking says less" do
      pid = spawn_link(fn -> receive(do: (:stop -> :ok)) end)
      known = %Identity{call: {My, :known, 0}, caller: self()}
      identity = Identity.read(pid, known)
      assert identity.call == {My, :known, 0}
      assert identity.caller == self()
      send(pid, :stop)
    end

    test "a label is what a process says it is" do
      if function_exported?(:proc_lib, :set_label, 1) do
        pid =
          spawn_link(fn ->
            :proc_lib.set_label({:connection, 42})
            receive(do: (:stop -> :ok))
          end)

        wait_until(fn -> Identity.read(pid).label != nil end)
        identity = Identity.read(pid)
        assert identity.label == {:connection, 42}
        assert Identity.group(identity) == "connection"
        send(pid, :stop)
      end
    end

    test "a process that is gone is nil" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert Identity.read(pid) == nil
    end
  end

  describe "names" do
    test "an atom is written without its colon" do
      assert Identity.text(:code_server) == "code_server"
      assert Identity.text(MyApp.Repo) == "MyApp.Repo"
      assert Identity.text(:"two words") == "two words"
      assert Identity.text(:"Elixir.lower.Case") == "Elixir.lower.Case"
    end

    test "an instance is named for what it is an instance of" do
      assert Identity.instance_of("worker_12") == "worker"
      assert Identity.instance_of("pool-3") == "pool"
      assert Identity.instance_of("MyApp.Registry.PIDPartition0") == "MyApp.Registry.PIDPartition"
      assert Identity.instance_of("shard_3_replica_2") == "shard_3_replica"
      assert Identity.instance_of("code_server") == "code_server"
      # A name that is nothing but a number is left as it is.
      assert Identity.instance_of("123") == "123"
      assert Identity.instance_of("_1") == "_1"
    end

    test "a process in one label" do
      assert Identity.proc("MyApp.Worker", self()) ==
               ("MyApp.Worker" <> inspect(self())) |> String.replace("#PID", "")

      assert Identity.pid_text(self()) =~ ~r/\A<0\.\d+\.\d+>\z/
    end
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("never happened")
      true -> Process.sleep(5) && wait_until(fun, tries - 1)
    end
  end
end
