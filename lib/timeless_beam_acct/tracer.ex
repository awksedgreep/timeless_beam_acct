defmodule TimelessBeamAcct.Tracer do
  @moduledoc """
  Hears from the VM of each process that starts and each that ends.

  Sampling sees a process only if it is alive at a sweep, and most are not:
  a request, a task, a query each live for milliseconds. The VM will say
  when each one starts and ends, to a process that asks. This is the
  process that asks.

  ## A trace session of its own

  Until OTP 27 a node had one tracer, and whoever asked last had it. A
  collector that traced every process would have taken `:dbg` and `:recon`
  away from whoever was using them, and lost its own exits to the next
  person who did. OTP 27 has trace sessions, each with its own tracer and
  its own settings, and this is one. On an older VM there is no tracer,
  and processes that end are noticed gone instead.

  Since OTP 28 a session also has its own system monitor, so what the VM
  remarks on (a long garbage collection, a long queue) is heard here
  without taking `:erlang.system_monitor/2` from an application that has
  set it. On OTP 27 a session has none. The node's one system monitor is
  not taken in its place, for the reason the node's one tracer is not, so
  there a tracer hears of each start and each end, and of no remarks.

  ## What is kept of what is heard

  The VM sends what a process was started with and the reason it ended
  with, whole. Either may be as large as what the process held. Each
  message is read as it arrives into the few words kept of it
  (`TimelessBeamAcct.Identity`, `TimelessBeamAcct.Ending`) and let go.
  What is kept goes into a table the collector empties at each tick.

  The collector reads the table directly and asks this process nothing: a
  question would wait its turn behind every message from the VM.

  ## What a process says it is

  What a process was started with says what it is, unless it is a task. A
  task that will be replied to is started with nothing, and is sent what
  to do afterwards. So the VM is also asked for word of two calls: the
  one by which a task takes up what it was sent, and the one by which a
  process gives itself a label. These are what the moment a process calls
  exec is on a host. A call that is not one of the two costs nothing
  more for it: the VM finds the two by marking them, and not by looking
  at every call.

  ## When there is too much to hear

  A node can start processes faster than one process can hear of them. If
  more than `:trace_max_queue` messages are waiting, the tracer stops
  listening, works through what it has, and listens again after
  `:trace_resume_after`. Processes that started and ended in between are
  not known of. Those that started in between and are still running are
  found by the next sweep, and those that ended are noticed gone.
  """

  use GenServer

  alias TimelessBeamAcct.{Ending, Identity, Options}

  @compile {:no_warn_undefined, :trace}

  # Counters, in the order they are kept.
  @spawns 1
  @exits 2
  @suspensions 3
  @remarks 4
  @remarks_dropped 5
  @listening 6
  @counters 6

  # How many messages are handled between two looks at how many wait.
  @look_every 512
  # Remarks of one kind about one process are recorded once in this long,
  # in milliseconds: a heap that is large is large at every collection.
  @window 10_000
  # A module loaded since the calls were marked has them unmarked. They
  # are marked again this often, in milliseconds.
  @mark_every 60_000

  # By which a task takes up what it was sent to do: what it returns is
  # what the task then says it was started with.
  @takes_up {Task.Supervised, :get_initial_call, 1}
  @labels {:proc_lib, :set_label, 1}

  @type handle :: %{table: :ets.tid(), counters: :counters.counters_ref(), pid: pid()}

  @type event ::
          {seq :: integer(), kind :: :born | :exit | :name | :unname | :remark | :gap,
           at :: integer(), subject :: pid() | port() | nil, data :: term()}

  @doc "Whether this VM has trace sessions."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(:trace) and function_exported?(:trace, :session_create, 3)
  end

  @doc """
  Whether a trace session of this VM has a system monitor of its own,
  which is what the VM's remarks are heard by.

  Trace sessions are of OTP 27, and `:trace.system/3` of OTP 28.
  """
  @spec remarks?() :: boolean()
  def remarks? do
    available?() and function_exported?(:trace, :system, 3)
  end

  @spec start_link(Options.t()) :: GenServer.on_start()
  def start_link(%Options{} = options) do
    GenServer.start_link(__MODULE__, options, name: Options.name(options, :Tracer))
  end

  @doc """
  What the collector reads the tracer by. Asked for once, when the
  collector starts, and `nil` if there is no tracer.
  """
  @spec handle(Options.t() | atom()) :: handle() | nil
  def handle(options) do
    case Process.whereis(Options.name(options, :Tracer)) do
      nil -> nil
      pid -> GenServer.call(pid, :handle)
    end
  catch
    :exit, _ -> nil
  end

  @doc """
  The number of the last thing heard of, or `nil` if nothing is waiting
  to be taken.

  What is heard of after this is asked has a later number, so a taking
  that stops here ends, however fast the node is starting processes.
  """
  @spec last(handle()) :: integer() | nil
  def last(%{table: table}) do
    case :ets.last(table) do
      :"$end_of_table" -> nil
      last -> last
    end
  rescue
    # The tracer has ended, and its table with it.
    ArgumentError -> nil
  end

  @doc """
  What was heard of, up to the number given and no more than `limit` of
  it at once, in the order it happened, and no longer in the table. `[]`
  when there is no more.

  It is taken a lot at a time so that a node that started a million
  processes since the last tick does not have them all in the collector's
  memory at once.

  Times are monotonic, in native units.
  """
  @spec take(handle(), integer() | nil, pos_integer()) :: [event()]
  def take(handle, upto \\ :last, limit \\ 50_000)

  def take(handle, :last, limit), do: take(handle, last(handle), limit)
  def take(_handle, nil, _limit), do: []

  def take(%{table: table}, upto, limit) do
    within = [{:"=<", :"$1", upto}]

    case :ets.select(table, [{{:"$1", :_, :_, :_, :_}, within, [:"$_"]}], limit) do
      :"$end_of_table" ->
        []

      {events, _continuation} ->
        {taken, _, _, _, _} = List.last(events)
        :ets.select_delete(table, [{{:"$1", :_, :_, :_, :_}, [{:"=<", :"$1", taken}], [true]}])
        # Heard in the order the messages came, which is the order things
        # happened for one process and not across several.
        Enum.sort_by(events, fn {seq, _kind, at, _subject, _data} -> {at, seq} end)
    end
  rescue
    ArgumentError -> []
  end

  @doc "What the tracer has counted since it started."
  @spec counts(handle()) :: %{
          spawns: non_neg_integer(),
          exits: non_neg_integer(),
          suspensions: non_neg_integer(),
          remarks: non_neg_integer(),
          remarks_dropped: non_neg_integer(),
          listening: boolean(),
          waiting: non_neg_integer()
        }
  def counts(%{counters: counters, table: table, pid: pid}) do
    waiting =
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, waiting} -> waiting
        nil -> 0
      end

    held =
      case :ets.info(table, :size) do
        :undefined -> 0
        size -> size
      end

    %{
      spawns: :counters.get(counters, @spawns),
      exits: :counters.get(counters, @exits),
      suspensions: :counters.get(counters, @suspensions),
      remarks: :counters.get(counters, @remarks),
      remarks_dropped: :counters.get(counters, @remarks_dropped),
      listening: :counters.get(counters, @listening) == 1,
      waiting: waiting + held
    }
  end

  ## The process

  @impl true
  def init(%Options{} = options) do
    if options.exits and available?() do
      # A long queue is walked at every garbage collection unless it is
      # kept off the heap.
      Process.flag(:message_queue_data, :off_heap)
      Process.flag(:trap_exit, true)

      session = :trace.session_create(Options.name(options, :Session), self(), [])

      state = %{
        options: options,
        session: session,
        table: :ets.new(:timeless_beam_acct_heard, [:ordered_set, :public]),
        counters: :counters.new(@counters, [:write_concurrency]),
        seq: 0,
        handled: 0,
        listening: false,
        window: {now_ms(), %{}, 0}
      }

      # Asked of a VM that has no `:trace.system/3`, it is a call to a
      # function that is not there, and the tracer would not start.
      if options.anomalies and remarks?(), do: monitor(session, options)
      if options.descriptions, do: send(self(), :mark)
      {:ok, listen(state)}
    else
      :ignore
    end
  end

  @impl true
  def terminate(_reason, state) do
    :trace.session_destroy(state.session)
    :ok
  catch
    _, _ -> :ok
  end

  @impl true
  def handle_call(:handle, _from, state) do
    {:reply, %{table: state.table, counters: state.counters, pid: self()}, state}
  end

  @impl true
  def handle_info({:trace_ts, pid, :spawned, parent, started_with, at}, state) do
    :counters.add(state.counters, @spawns, 1)
    identity = Identity.of_spawn(started_with)
    {:noreply, state |> heard(:born, at, pid, {parent, identity}) |> look()}
  end

  def handle_info({:trace_ts, pid, :exit, reason, at}, state) do
    :counters.add(state.counters, @exits, 1)
    {:noreply, state |> heard(:exit, at, pid, Ending.of(reason)) |> look()}
  end

  def handle_info({:trace_ts, pid, :register, name, at}, state),
    do: {:noreply, state |> heard(:name, at, pid, name) |> look()}

  def handle_info({:trace_ts, pid, :unregister, name, at}, state),
    do: {:noreply, state |> heard(:unname, at, pid, name) |> look()}

  def handle_info({:trace_ts, pid, :return_from, @takes_up, {module, function, arity}, at}, state)
      when is_atom(module) and is_atom(function) and is_integer(arity) do
    # A function called with arguments says only that it was called.
    if {module, function} == {:erlang, :apply},
      do: {:noreply, look(state)},
      else: {:noreply, state |> heard(:call, at, pid, {module, function, arity}) |> look()}
  end

  def handle_info({:trace_ts, pid, :call, @labels, label, at}, state) do
    group = Identity.group(%Identity{label: label})
    {:noreply, state |> heard(:label, at, pid, group) |> look()}
  end

  # The rest of what is said of processes: links, each start a second
  # time, from the side of the process that did the starting, and each
  # call that is heard of by what it returns.
  def handle_info(message, state) when elem(message, 0) == :trace_ts, do: {:noreply, look(state)}

  def handle_info({:monitor, subject, kind, info}, state),
    do: {:noreply, state |> remark(kind, subject, info) |> look()}

  def handle_info(:mark, state) do
    mark(state.session)
    Process.send_after(self(), :mark, @mark_every)
    {:noreply, state}
  end

  def handle_info(:resume, %{listening: false} = state) do
    {:message_queue_len, waiting} = Process.info(self(), :message_queue_len)

    if waiting > div(state.options.trace_max_queue, 2) do
      # Still working through what was heard before.
      wait(state)
      {:noreply, state}
    else
      {:noreply, state |> heard(:gap, mono(), nil, :end) |> listen()}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Listening

  defp listen(state) do
    :trace.process(state.session, :all, true, flags(state.options))
    :counters.put(state.counters, @listening, 1)
    %{state | listening: true}
  end

  # With `:arity`, a call is told of without what it was called with,
  # which may be all that a task was given to work on.
  defp flags(%Options{descriptions: true}),
    do: [:procs, :call, :arity, :monotonic_timestamp]

  defp flags(%Options{}), do: [:procs, :monotonic_timestamp]

  defp mark(session) do
    Code.ensure_loaded(Task.Supervised)
    :trace.function(session, @takes_up, [{:_, [], [{:return_trace}]}], [:local])
    :trace.function(session, @labels, [{[:"$1"], [], [{:message, :"$1"}]}], [])
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp suspend(state) do
    :trace.process(state.session, :all, false, [:procs, :call])
    :counters.put(state.counters, @listening, 0)
    :counters.add(state.counters, @suspensions, 1)
    wait(state)
    %{state | listening: false} |> heard(:gap, mono(), nil, :begin)
  end

  defp wait(state),
    do: Process.send_after(self(), :resume, round(state.options.trace_resume_after * 1000))

  defp monitor(session, options) do
    word = :erlang.system_info(:wordsize)

    for {event, value} <- [
          long_gc: options.long_gc,
          long_schedule: options.long_schedule,
          large_heap: options.large_heap && max(div(options.large_heap, word), 1),
          long_message_queue: options.long_message_queue,
          busy_port: options.busy_port,
          busy_dist_port: options.busy_dist_port
        ],
        value do
      try do
        :trace.system(session, event, value)
      rescue
        # Not an event this VM remarks on.
        ArgumentError -> :ok
      end
    end
  end

  # Every so often, how much is waiting is looked at. Looking costs more
  # than handling a message does.
  defp look(%{handled: handled} = state) when handled < @look_every,
    do: %{state | handled: handled + 1}

  defp look(%{listening: false} = state), do: %{state | handled: 0}

  defp look(state) do
    {:message_queue_len, waiting} = Process.info(self(), :message_queue_len)
    limit = state.options.trace_max_queue
    # What the collector has not taken counts too: it is not keeping up
    # either.
    held = :ets.info(state.table, :size)

    if waiting > limit or held > 8 * limit,
      do: suspend(%{state | handled: 0}),
      else: %{state | handled: 0}
  end

  defp heard(state, kind, at, subject, data) do
    seq = state.seq + 1
    :ets.insert(state.table, {seq, kind, at, subject, data})
    %{state | seq: seq}
  end

  ## Remarks

  defp remark(state, kind, subject, info) do
    now = now_ms()
    {began, seen, count} = state.window
    {seen, count} = if now - began >= @window, do: {%{}, 0}, else: {seen, count}
    began = if count == 0 and seen == %{}, do: now, else: began
    key = {kind, subject, info == false}

    cond do
      is_map_key(seen, key) or count >= state.options.max_anomalies ->
        :counters.add(state.counters, @remarks_dropped, 1)
        %{state | window: {began, seen, count}}

      true ->
        :counters.add(state.counters, @remarks, 1)
        {value, detail} = remarked(kind, subject, info)

        %{state | window: {began, Map.put(seen, key, true), count + 1}}
        |> heard(:remark, mono(), subject, {kind, value, detail})
    end
  end

  defp remarked(kind, _subject, info) when kind in [:long_gc, :long_schedule] and is_list(info) do
    detail =
      case {info[:in], info[:out], info[:port_op]} do
        {_, _, op} when not is_nil(op) -> "#{op}"
        {_, {m, f, a}, _} -> Exception.format_mfa(m, f, a)
        {{m, f, a}, _, _} -> Exception.format_mfa(m, f, a)
        _ -> nil
      end

    {info[:timeout], detail}
  end

  defp remarked(:large_heap, _subject, info) when is_list(info) do
    words =
      Keyword.get(info, :heap_block_size, 0) + Keyword.get(info, :old_heap_block_size, 0) +
        Keyword.get(info, :mbuf_size, 0)

    {words * :erlang.system_info(:wordsize), nil}
  end

  defp remarked(:long_message_queue, subject, long) when is_pid(subject) do
    waiting =
      case Process.info(subject, :message_queue_len) do
        {:message_queue_len, waiting} -> waiting
        nil -> nil
      end

    {waiting, if(long, do: "raised", else: "cleared")}
  end

  defp remarked(kind, _subject, port) when kind in [:busy_port, :busy_dist_port],
    do: {nil, inspect(port)}

  defp remarked(_kind, _subject, _info), do: {nil, nil}

  defp mono, do: :erlang.monotonic_time()
  defp now_ms, do: :erlang.monotonic_time(:millisecond)
end
