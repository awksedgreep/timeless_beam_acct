defmodule TimelessBeamAcct.Identity do
  @moduledoc """
  What a process is.

  A pid says which process, and nothing of what it is for. What it is for is
  learned from the first of these that applies:

  1. **the name it is registered under**, which someone chose for it;
  2. **its label**, which it gave itself (`:proc_lib.set_label/1`, OTP 27);
  3. **the call it was started with**, as `:proc_lib` and `Task` record it:
     the callback module of a server, the function of a task;
  4. **the function it was spawned with**.

  That is its **group**: what it is counted under, among all the processes
  that are the same thing.

  The third and fourth are read from the process while it lives. Most
  processes are gone before anything can read them, so they are also worked
  out from the arguments a process was started with, which the VM reports
  with the start itself.
  """

  @type call :: {module(), atom(), arity()}

  @type t :: %__MODULE__{
          call: call() | nil,
          name: atom() | nil,
          label: term(),
          caller: pid() | nil,
          parent: pid() | nil,
          group_leader: pid() | nil
        }

  defstruct [:call, :name, :label, :caller, :parent, :group_leader]

  # The processes that start jobs and are not part of them.
  @starters [:supervisor, :supervisor_bridge, :application_master, :ranch_conns_sup]

  @items [
    :registered_name,
    :initial_call,
    :group_leader,
    :parent,
    {:dictionary, :"$initial_call"},
    {:dictionary, :"$process_label"},
    {:dictionary, :"$callers"}
  ]

  @doc """
  What a process is, from what it was started with: the third element of
  the VM's word that a process was `spawned`.

  The arguments are looked at and let go. They are whatever the process was
  given to work on, and may be large.
  """
  @spec of_spawn({module(), atom(), list()} | term()) :: t()
  def of_spawn({:proc_lib, :init_p, [_parent, _ancestors, fun]}) when is_function(fun),
    do: %__MODULE__{call: of_fun(fun)}

  def of_spawn({:proc_lib, :init_p, [_parent, _ancestors, module, function, args]})
      when is_atom(module) and is_atom(function) and is_list(args) do
    %__MODULE__{call: translate(module, function, args), name: given_name(module, function, args)}
  end

  def of_spawn({Task.Supervised, function, [owner | _] = args}) when is_atom(function) do
    %__MODULE__{call: of_task(function, args), caller: owner_of(owner)}
  end

  def of_spawn({:erlang, :apply, [fun, args]}) when is_function(fun) and is_list(args),
    do: %__MODULE__{call: of_fun(fun)}

  # Started from another node, which says what it is to run.
  def of_spawn({:erts_internal, :dist_spawn_init, [{module, function, arity}]})
      when is_atom(module) and is_atom(function) and is_integer(arity),
      do: %__MODULE__{call: {module, function, arity}}

  def of_spawn({module, function, args})
      when is_atom(module) and is_atom(function) and is_list(args),
      do: %__MODULE__{call: {module, function, length(args)}}

  def of_spawn(_unknown), do: %__MODULE__{}

  # As `:proc_lib` translates what it was given, so that a process is the
  # same thing here as it will say it is when it is asked.
  defp translate(:gen, :init_it, [:gen_server, _, _, :supervisor, {_, module, _}, _]),
    do: {:supervisor, module, 1}

  defp translate(:gen, :init_it, [:gen_server, _, _, _, :supervisor, {_, module, _}, _]),
    do: {:supervisor, module, 1}

  defp translate(:gen, :init_it, [:gen_server, _, _, :supervisor_bridge, [module | _], _]),
    do: {:supervisor_bridge, module, 1}

  defp translate(:gen, :init_it, [:gen_server, _, _, _, :supervisor_bridge, [module | _], _]),
    do: {:supervisor_bridge, module, 1}

  defp translate(:gen, :init_it, [:gen_event | _]), do: {:gen_event, :init_it, 6}

  # A dynamic supervisor is a server that says it is a supervisor once it
  # is running.
  defp translate(:gen, :init_it, [_, _, _, DynamicSupervisor, {module, _, _}, _])
       when is_atom(module),
       do: {:supervisor, module, 1}

  defp translate(:gen, :init_it, [_, _, _, _, DynamicSupervisor, {module, _, _}, _])
       when is_atom(module),
       do: {:supervisor, module, 1}

  defp translate(:gen, :init_it, [_, _, _, module, _, _]) when is_atom(module),
    do: {module, :init, 1}

  defp translate(:gen, :init_it, [_, _, _, _, module | _]) when is_atom(module),
    do: {module, :init, 1}

  defp translate(module, function, args), do: {module, function, length(args)}

  # A server started under a name has it among its arguments, before it has
  # registered it.
  defp given_name(:gen, :init_it, [_, _, _, {:local, name}, _, _, _]) when is_atom(name),
    do: name

  defp given_name(_module, _function, _args), do: nil

  # A task that is not replied to is started with its function. One that is
  # replied to is sent its function afterwards, and is known here only as a
  # task.
  defp of_task(function, args) do
    case List.last(args) do
      {:erlang, :apply, [fun, _]} when is_function(fun) ->
        of_fun(fun)

      {module, called, given} when is_atom(module) and is_atom(called) and is_list(given) ->
        {module, called, length(given)}

      _ ->
        {Task.Supervised, function, length(args)}
    end
  end

  defp owner_of({_node, owner, _alias}) when is_pid(owner) and node(owner) == node(), do: owner
  defp owner_of(_), do: nil

  defp of_fun(fun) do
    {:module, module} = :erlang.fun_info(fun, :module)
    {:name, name} = :erlang.fun_info(fun, :name)
    {:arity, arity} = :erlang.fun_info(fun, :arity)
    {module, name, arity}
  end

  @doc """
  What a living process is, by asking it. `nil` if it is gone.

  `known` is what it was taken to be from its start, if its start was heard
  of. What it was spawned with is kept where asking says less: a process
  spawned with a function says only that it was spawned with one.
  """
  @spec read(pid(), t() | nil) :: t() | nil
  def read(pid, known \\ nil) do
    case info(pid, @items) do
      nil ->
        nil

      info ->
        %__MODULE__{
          name: name_of(info[:registered_name]),
          label: defined(info[{:dictionary, :"$process_label"}]),
          call: call_of(pid, info, known),
          caller: caller_of(info[{:dictionary, :"$callers"}]) || (known && known.caller),
          parent: parent_of(info[:parent]),
          group_leader: info[:group_leader]
        }
    end
  end

  # One key of a dictionary can be asked for since OTP 26.2. Before that the
  # whole dictionary is asked for, which is whatever the process has put in
  # it. It is asked for once in a process's life.
  defp info(pid, items) do
    :erlang.process_info(pid, items) |> listed()
  rescue
    ArgumentError ->
      {keys, plain} = Enum.split_with(items, &match?({:dictionary, _}, &1))

      case safely(fn -> :erlang.process_info(pid, [:dictionary | plain -- [:parent]]) end) do
        nil ->
          nil

        info ->
          dictionary = info[:dictionary] || []

          for {:dictionary, key} <- keys, reduce: Map.new(info) do
            acc -> Map.put(acc, {:dictionary, key}, Keyword.get(dictionary, key, :undefined))
          end
      end
  end

  defp listed(:undefined), do: nil
  defp listed(info), do: Map.new(info)

  defp safely(fun) do
    fun.() |> listed()
  rescue
    ArgumentError -> nil
  end

  defp name_of([]), do: nil
  defp name_of(nil), do: nil
  defp name_of(name) when is_atom(name), do: name

  defp defined(:undefined), do: nil
  defp defined(value), do: value

  defp parent_of(pid) when is_pid(pid), do: pid
  defp parent_of(_), do: nil

  defp caller_of([caller | _]) when is_pid(caller) and node(caller) == node(), do: caller
  defp caller_of(_), do: nil

  defp call_of(pid, info, known) do
    case {info[{:dictionary, :"$initial_call"}], info[:initial_call]} do
      {{module, function, arity}, _}
      when is_atom(module) and is_atom(function) and is_integer(arity) ->
        {module, function, arity}

      {_, {:erlang, :apply, 2}} ->
        (known && known.call) || bottom_of_stack(pid) || {:erlang, :apply, 2}

      {_, {:proc_lib, :init_p, _}} ->
        (known && known.call) || {:proc_lib, :init_p, 5}

      {_, {module, function, arity}} ->
        {module, function, arity}

      _ ->
        known && known.call
    end
  end

  # A process spawned with a function, whose start was not heard of. The
  # function is at the bottom of its stack, unless it has since called
  # another in its own place.
  defp bottom_of_stack(pid) do
    case :erlang.process_info(pid, :current_stacktrace) do
      {:current_stacktrace, [_ | _] = stack} ->
        case List.last(stack) do
          {module, function, arity, _} when is_atom(module) and is_integer(arity) ->
            {module, function, arity}

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  The group of a process: what it is counted under.

  An instance is named for what it is an instance of. A pool registers its
  workers as `worker_1` to `worker_50`, and a registry its partitions as
  `PIDPartition0` to `PIDPartition21`. Under those names each would be a
  line of its own, and the pool would not have one. The number is removed,
  and the instances are counted together. They can be told apart where
  each process has its own series, which is under its full name.
  """
  @spec group(t()) :: String.t()
  def group(%__MODULE__{name: name}) when not is_nil(name), do: name |> text() |> instance_of()

  def group(%__MODULE__{label: label}) when not is_nil(label),
    do: label |> label_text() |> instance_of()

  def group(%__MODULE__{call: call}) when not is_nil(call), do: call_group(call)
  def group(%__MODULE__{}), do: "unknown"

  # A server is its callback module. What it was started with is always
  # `init/1`, which says nothing.
  defp call_group({behaviour, module, _}) when behaviour in [:supervisor, :supervisor_bridge],
    do: text(module)

  defp call_group({module, :init, 1}), do: text(module)

  defp call_group({module, function, arity}) do
    case anonymous(Atom.to_string(function)) do
      {within, of_arity} -> "fn in #{text(module)}.#{within}/#{of_arity}"
      nil -> "#{text(module)}.#{function}/#{arity}"
    end
  end

  # A function with no name is named by the compiler for the function it
  # is in: `-handle_info/2-fun-0-`.
  defp anonymous("-" <> rest) do
    rest
    |> :binary.matches("/")
    |> Enum.find_value(fn {at, 1} ->
      <<within::binary-size(^at), "/", then::binary>> = rest

      case Integer.parse(then) do
        {arity, "-" <> _} when within != "" -> {within, arity}
        _ -> nil
      end
    end)
  end

  defp anonymous(_named), do: nil

  @doc "The call a process was started with, as it is written: `MyApp.Worker.init/1`."
  @spec path(t()) :: String.t() | nil
  def path(%__MODULE__{call: {behaviour, module, arity}})
      when behaviour in [:supervisor, :supervisor_bridge],
      do: "#{text(module)}.init/#{arity}"

  def path(%__MODULE__{call: {module, function, arity}}),
    do: "#{text(module)}.#{function}/#{arity}"

  def path(%__MODULE__{}), do: nil

  @doc "The name a process is registered under, as it is written, or `nil`."
  @spec name(t()) :: String.t() | nil
  def name(%__MODULE__{name: nil}), do: nil
  def name(%__MODULE__{name: name}), do: text(name)

  @doc """
  Whether a process starts jobs and is not part of them: a supervisor, or
  a process of one of the modules named in `also`.
  """
  @spec starter?(t(), [module()]) :: boolean()
  def starter?(identity, also \\ [])

  def starter?(%__MODULE__{call: {module, callback, _}}, also),
    do: module in @starters or module in also or callback in also

  def starter?(%__MODULE__{}, _also), do: false

  @doc """
  One process, in one label: `MyApp.Worker<0.512.0>`.
  """
  @spec proc(String.t(), pid()) :: String.t()
  def proc(name, pid), do: name <> pid_text(pid)

  @doc "`<0.512.0>`."
  @spec pid_text(pid()) :: String.t()
  def pid_text(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  @doc """
  An atom as a name: `MyApp.Repo`, `code_server`.

  As it is written, without the colon, and without the quotes an atom is
  written in when it is not a word: a name is read by people, and is
  quoted again by whatever stores it.
  """
  @spec text(atom()) :: String.t()
  def text(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      <<"Elixir.", first, _::binary>> = module when first in ?A..?Z ->
        binary_part(module, 7, byte_size(module) - 7)

      plain ->
        plain
    end
  end

  # A label is any term. The first word of it says what kind of thing the
  # process is, and the rest which.
  defp label_text(label) when is_atom(label), do: text(label)
  defp label_text(label) when is_binary(label), do: printable(label)

  defp label_text(label) when is_tuple(label) and tuple_size(label) > 0,
    do: label |> elem(0) |> label_text()

  defp label_text(label), do: label |> inspect(limit: 5, printable_limit: 64) |> printable()

  defp printable(text) do
    text = if String.valid?(text), do: text, else: inspect(text, limit: 5, printable_limit: 64)
    String.slice(text, 0, 64)
  end

  @doc """
  A name without the number that says which instance it is.
  """
  @spec instance_of(String.t()) :: String.t()
  def instance_of(name) do
    case Regex.run(~r/\A(.*?[^0-9_\-.])[_\-.]*[0-9]+\z/s, name) do
      [_, kind] -> kind
      nil -> name
    end
  end
end
