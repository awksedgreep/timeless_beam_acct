defmodule TimelessBeamAcct.Processes do
  @moduledoc """
  The processes of the node: those heard of, and those a sweep finds.

  ## Every process decides the tiers

  The obvious design is a set of series for each pid. A node that answers
  requests starts a process for each and ends it milliseconds later. A
  series costs a catalog entry of a few hundred bytes whether it holds one
  point or a million. That is millions of dead series a day, to record
  processes that were never alive at a moment anyone sampled.

  And unlike a host, a node may have a hundred thousand processes that do
  live long: one for each connection. So age alone does not decide who
  gets series, as it does for the processes of a host.

  | tier | what | how many |
  |---|---|---|
  | `beam_app_*` | one application | the applications that are running |
  | `beam_group_*` | everything that is the same thing, together | `:max_groups`, and `other` |
  | `beam_proc_*` | one process | `:max_processes`: those with a name, then those that are large |
  | accounting record | a process that ended | none: it is a row, not a series |

  ## Who gets series of their own

  A process that has lived for `:min_age`, and either is registered under
  a name, which is a process someone means to be able to find, or is
  notable: it holds `:notable_memory`, or has `:notable_queue` messages
  waiting, or does `:notable_work` percent of the node's reductions.

  A process that is given series keeps them until it ends. If places were
  given afresh at each sweep to whoever was largest, a process near the
  edge would be a line on one reading and absent from the next.

  ## A name that has a place is reported at every reading

  A group or an application that has no processes is reported as having
  none, for as long as it keeps its place. A reader takes the last sample
  of a series as its value, and the last sample of a pool that has
  emptied would otherwise say that it is as full as it last was.

  ## What the totals hold

  The totals of a group are over every living process in it, whatever its
  age. A process that was not there at the last sweep was started since, so
  all it has used belongs to this interval.

  What a process used between the last sweep that saw it and its end is
  not in them, nor is anything of a process that no sweep saw: the VM does
  not say what a process had used when it ended. `beam_vm_reductions_per_sec`
  is the node's own count and misses nothing, and
  `beam_acct_reductions_accounted_pct` says how much of it the sweep found
  a process for.
  """

  import TimelessBeamAcct.Tracked

  # Of OTP 28, and called only where they are found.
  @compile {:no_warn_undefined,
            [{:erlang, :processes_iterator, 0}, {:erlang, :processes_next, 1}]}

  alias TimelessBeamAcct.{Admission, Batch, Ended, Ending, Identity, Lineage, Options, Tracked}

  @type exit :: {pid(), Ending.t(), at :: integer()}
  @type remark ::
          {kind :: atom(), subject :: pid() | port(), value :: number() | nil,
           detail :: String.t() | nil, at :: integer()}

  @type t :: %__MODULE__{}

  defstruct [
    :options,
    :table,
    :incarnation,
    :max_age,
    :min_age,
    gen: 0,
    # When the last sweep began, and the node's reductions as of then.
    last: nil,
    vm_reductions: 0,
    groups: nil,
    apps: nil,
    # Whether `other` has been reported, and so is reported from then on.
    others: false,
    admitted: 0,
    # Starts, ends, and failures since the last sweep, by group and by
    # application.
    tallies: %{groups: %{}, apps: %{}},
    # Whether the VM is telling of each process that ends.
    listening: false
  ]

  @figures [:reductions, :memory, :message_queue_len, :registered_name]
  # More than there are of anything that is reported without a limit.
  @every 1_000_000

  @doc """
  The table is made here, and belongs to the process that calls this.
  """
  @spec new(Options.t()) :: t()
  def new(%Options{} = options) do
    table =
      :ets.new(Options.name(options, :Processes), [
        :named_table,
        :set,
        :protected,
        keypos: Tracked.keypos(),
        read_concurrency: true
      ])

    %__MODULE__{
      options: options,
      table: table,
      incarnation: Lineage.incarnation(),
      max_age: native(options.trace_max_age),
      min_age: native(options.min_age),
      groups: Admission.new(options.max_groups),
      # Every application is reported by name. They are kept as the
      # groups are so that one that stops is reported as nothing.
      apps: Admission.new(@every)
    }
  end

  @doc "Whether the VM is telling of each process that ends."
  @spec listening(t(), boolean()) :: t()
  def listening(%__MODULE__{} = state, listening), do: %{state | listening: listening}

  @doc "How many processes have series of their own."
  @spec admitted(t()) :: non_neg_integer()
  def admitted(%__MODULE__{admitted: admitted}), do: admitted

  ## What was heard

  @doc """
  Take in what the tracer heard since the last tick.

  Everything that started is laid out before any of it is given its place.
  A child is heard of before its parent as often as after.

  Returns what ended and what was remarked on, which are accounted once
  every process heard of has its place.
  """
  @spec heard(t(), [TimelessBeamAcct.Tracer.event()]) :: {t(), [exit()], [remark()]}
  def heard(%__MODULE__{} = state, events) do
    {births, exits, remarks} =
      Enum.reduce(events, {[], [], []}, fn
        {_, :born, at, pid, {parent, identity}}, {births, exits, remarks} ->
          born(state, pid, parent, identity, at)
          {[pid | births], exits, remarks}

        {_, :exit, at, pid, ending}, {births, exits, remarks} ->
          {births, [{pid, ending, at} | exits], remarks}

        {_, :name, _at, pid, name}, acc ->
          named(state, pid, Identity.text(name))
          acc

        # A process that ends registered is said to have ended, and then
        # to have given up its name. It is accounted under the name it
        # ended under, so what comes after its end is not taken in.
        {_, :unname, _at, pid, _name}, {_births, exits, _remarks} = acc ->
          unless List.keymember?(exits, pid, 0), do: named(state, pid, nil)
          acc

        {_, :call, _at, pid, call}, acc ->
          described(state, pid, call)
          acc

        {_, :label, _at, pid, label}, acc ->
          labelled(state, pid, label)
          acc

        {_, :remark, at, subject, {kind, value, detail}}, {births, exits, remarks} ->
          {births, exits, [{kind, subject, value, detail, at} | remarks]}

        _gap_or_unknown, acc ->
          acc
      end)

    births = Enum.reverse(births)
    Enum.each(births, &Lineage.settle(state.table, &1, state.max_age))

    state =
      Enum.reduce(births, state, fn pid, state ->
        case :ets.lookup(state.table, pid) do
          [tracked(group: group, app: app)] -> tally(state, group, app, :spawns)
          [] -> state
        end
      end)

    {state, Enum.reverse(exits), Enum.reverse(remarks)}
  end

  defp born(state, pid, parent, %Identity{} = identity, at) do
    case :ets.lookup(state.table, pid) do
      [] ->
        :ets.insert(
          state.table,
          tracked(
            pid: pid,
            gen: state.gen,
            since: at,
            born: true,
            parent: parent,
            caller: identity.caller,
            call: identity.call,
            base: Identity.group(%{identity | name: nil}),
            group: Identity.group(identity),
            path: Identity.path(identity),
            name: Identity.name(identity),
            starter: Identity.starter?(identity, state.options.trace_roots)
          )
        )

      # A sweep found it before word of its start was taken in. It has its
      # place, and keeps it.
      [tracked(born: false) = row] ->
        :ets.insert(state.table, tracked(row, since: at, born: true, parent: parent))

      # A pid that was another process's, whose end was not heard of.
      [_stale] ->
        :ets.delete(state.table, pid)
        born(state, pid, parent, identity, at)
    end
  end

  defp named(state, pid, name) do
    case :ets.lookup(state.table, pid) do
      [row] -> :ets.insert(state.table, rename(row, name))
      [] -> :ok
    end
  end

  # What a task was given to do, which is what it is from then on.
  defp described(state, pid, call) do
    case :ets.lookup(state.table, pid) do
      [row] ->
        identity = %Identity{call: call}

        :ets.insert(
          state.table,
          row
          |> tracked(call: call, path: Identity.path(identity))
          |> rebase(Identity.group(identity))
        )

      [] ->
        :ok
    end
  end

  defp labelled(state, pid, label) do
    case :ets.lookup(state.table, pid) do
      [row] -> :ets.insert(state.table, rebase(row, label))
      [] -> :ok
    end
  end

  # A name someone gave it says more than what it says of itself.
  defp rebase(tracked(name: nil) = row, base), do: tracked(row, base: base, group: base)
  defp rebase(row, base), do: tracked(row, base: base)

  defp rename(tracked(base: base) = row, nil), do: tracked(row, name: nil, group: base)
  defp rename(row, name), do: tracked(row, name: name, group: Identity.instance_of(name))

  ## What ended

  @typedoc """
  How many more of those that ended may be described: of those that ended
  as they were meant to, and of those that did not.
  """
  @type room :: %{ordinary: non_neg_integer(), failed: non_neg_integer()}

  @doc """
  What is known of each process that ended, for as many as there is room
  for. None of them is tracked any longer, and all of them are counted.

  Describing a process is most of what accounting for it costs, and a
  node may end ten thousand a second. Those there is no room for are
  counted and let go: `{state, described, room_left, let_go}`.
  """
  @spec ended(t(), [exit()], room()) :: {t(), [Ended.t()], room(), non_neg_integer()}
  def ended(%__MODULE__{} = state, exits, room \\ %{ordinary: :infinity, failed: :infinity}) do
    # All of them are described before any is forgotten: a process is
    # described by its parent, which may have ended in the same tick.
    {described, room, let_go} =
      Enum.reduce(exits, {[], room, 0}, fn {pid, ending, at}, {described, room, let_go} ->
        row =
          case :ets.lookup(state.table, pid) do
            [row] -> row
            [] -> nil
          end

        kind = if Ending.ok?(ending) == false, do: :failed, else: :ordinary

        if room[kind] > 0 do
          ended =
            if row,
              do: describe(state, row, ending, at, :traced),
              else: unheard_of(pid, ending, at)

          {[{row, ended} | described], spend(room, kind), let_go}
        else
          {[{row, counted(row, ending)} | described], room, let_go + 1}
        end
      end)

    state =
      Enum.reduce(described, state, fn {row, ended}, state ->
        state |> forget(row) |> tally(ended)
      end)

    {state, for({_row, %Ended{} = ended} <- Enum.reverse(described), do: ended), room, let_go}
  end

  defp spend(room, kind) do
    case room do
      %{^kind => :infinity} -> room
      %{^kind => left} -> %{room | kind => left - 1}
    end
  end

  # All that is kept of a process there was no room to describe: what it
  # is counted under.
  defp counted(nil, ending), do: {"unknown", "none", ending}
  defp counted(tracked(group: group, app: app), ending), do: {group, app, ending}

  defp forget(state, nil), do: state

  defp forget(state, tracked(pid: pid, admitted: admitted)) do
    :ets.delete(state.table, pid)
    if admitted, do: %{state | admitted: max(state.admitted - 1, 0)}, else: state
  end

  defp describe(state, row, ending, at, source) do
    tracked(pid: pid, parent: parent, caller: caller, since: since, swept: swept) = row

    %Ended{
      pid: Identity.pid_text(pid),
      group: tracked(row, :group),
      name: tracked(row, :name),
      path: tracked(row, :path),
      app: tracked(row, :app) || "none",
      parent: parent && Identity.pid_text(parent),
      parent_group: parent && group_of(state, parent),
      caller: caller && caller != parent && Identity.pid_text(caller),
      since: epoch_us(since),
      born: tracked(row, :born),
      ended: epoch_us(max(at, since)),
      ending: ending,
      source: source,
      figures:
        swept &&
          %{
            reductions: tracked(row, :reductions),
            memory: tracked(row, :memory),
            peak_memory: tracked(row, :peak_memory),
            queue: tracked(row, :queue),
            at: epoch_us(swept)
          },
      place: if(state.options.traces, do: Lineage.place(state.incarnation, row))
    }
    |> clean()
  end

  # It started and ended while no one was listening, or before anyone was.
  defp unheard_of(pid, ending, at) do
    %Ended{
      pid: Identity.pid_text(pid),
      group: "unknown",
      since: epoch_us(at),
      born: false,
      ended: epoch_us(at),
      ending: ending,
      source: :traced
    }
  end

  defp clean(%Ended{caller: false} = ended), do: %{ended | caller: nil}
  defp clean(ended), do: ended

  defp group_of(state, pid) do
    case :ets.lookup(state.table, pid) do
      [tracked(group: group)] -> group
      [] -> nil
    end
  end

  defp tally(state, %Ended{group: group, app: app, ending: ending}),
    do: tally(state, {group, app, ending})

  defp tally(state, {group, app, ending}) do
    state = tally(state, group, app, :exits)
    if Ending.ok?(ending) == false, do: tally(state, group, app, :failures), else: state
  end

  defp tally(state, group, app, what) do
    %{groups: groups, apps: apps} = state.tallies
    bump = &Map.update(&1, what, 1, fn count -> count + 1 end)

    %{
      state
      | tallies: %{
          groups: Map.update(groups, group, bump.(%{}), bump),
          apps: Map.update(apps, app || "none", bump.(%{}), bump)
        }
    }
  end

  ## The sweep

  @doc """
  Read every process, and report.

  `by_owner` is the memory of tables by the process that owns each, which
  is charged to that process's application.

  Returns the processes that were there at an earlier sweep and are gone
  with no word of their end, and what the sweep found:
  `%{processes:, seconds:}`.

  The first sweep is for the differences it makes possible: it reports
  what needs no difference, and no rates.
  """
  @spec sweep(t(), Batch.t(), %{pid() => non_neg_integer()}) ::
          {t(), Batch.t(), [Ended.t()], %{processes: non_neg_integer(), seconds: float()}}
  def sweep(%__MODULE__{} = state, %Batch{} = batch, by_owner \\ %{}) do
    now = mono()
    gen = state.gen + 1
    {vm_reductions, _} = :erlang.statistics(:reductions)

    context = %{
      table: state.table,
      gen: gen,
      now: now,
      first: is_nil(state.last),
      seconds: state.last && seconds(now - state.last),
      vm_delta: state.last && vm_reductions - state.vm_reductions,
      masters: masters(),
      options: state.options,
      min_age: state.min_age,
      room: state.options.max_processes > state.admitted
    }

    found = %{
      batch: batch,
      groups: %{},
      apps: %{},
      new: [],
      candidates: [],
      processes: 0,
      accounted: 0
    }

    found = each_process(found, &visit(&1, &2, context))

    Enum.each(found.new, &Lineage.settle(state.table, &1, state.max_age))

    {state, batch} = admit(state, found, context)
    {state, vanished} = vanished(%{state | gen: gen}, now)

    # Places are given before the report is made, so that a group is
    # reported as itself from the first reading of it. A group none of
    # whose processes lived to the sweep is present too: what answers
    # requests is such a group.
    brief = for {group, tally} <- state.tallies.groups, do: {group, Map.get(tally, :spawns, 0)}
    living = for {group, total} <- found.groups, do: {group, total.memory + total.work}
    present = Map.merge(Map.new(brief), Map.new(living), fn _group, a, b -> a + b end)
    state = %{state | groups: Admission.reading(state.groups, present)}
    {state, batch} = report_groups(state, batch, found.groups, context)

    {state, batch} =
      if state.options.apps,
        do: report_apps(state, batch, found.apps, by_owner, context),
        else: {state, batch}

    batch =
      batch
      |> Batch.push("beam_acct_processes", found.processes)
      |> Batch.push("beam_acct_processes_reported", state.admitted)
      |> Batch.push("beam_acct_groups", map_size(found.groups))
      |> Batch.push("beam_acct_reductions_accounted_pct", accounted(found.accounted, context))

    took = seconds(mono() - now)

    state = %{
      state
      | last: now,
        vm_reductions: vm_reductions,
        tallies: %{groups: %{}, apps: %{}}
    }

    {state, Batch.push(batch, "beam_acct_sweep_seconds", took), vanished,
     %{processes: found.processes, seconds: took}}
  end

  # The sweep's own sum is of readings taken one after another, and the
  # node's count is of one moment, so the first can be a little the larger.
  defp accounted(_accounted, %{vm_delta: nil}), do: nil

  defp accounted(accounted, %{vm_delta: delta}),
    do: min(Batch.pct(accounted, delta) || 0.0, 100.0)

  defp each_process(acc, visit) do
    if function_exported?(:erlang, :processes_iterator, 0) do
      iterate(:erlang.processes_iterator(), acc, visit)
    else
      Enum.reduce(:erlang.processes(), acc, visit)
    end
  end

  defp iterate(iterator, acc, visit) do
    case :erlang.processes_next(iterator) do
      :none -> acc
      {pid, iterator} -> iterate(iterator, visit.(pid, acc), visit)
    end
  end

  defp visit(pid, found, context) do
    case :erlang.process_info(pid, @figures) do
      :undefined ->
        found

      [reductions: reductions, memory: memory, message_queue_len: queue, registered_name: name] ->
        name = if name == [], do: nil, else: Identity.text(name)

        case :ets.lookup(context.table, pid) do
          [row] -> seen(row, found, context, {reductions, memory, queue, name})
          [] -> discovered(pid, found, context, {reductions, memory, queue, name})
        end
    end
  end

  # Not known of until now: it was running before the collector was, or
  # started while no one was listening.
  defp discovered(pid, found, context, {reductions, memory, queue, _name} = figures) do
    case Identity.read(pid) do
      nil ->
        found

      identity ->
        row =
          tracked(
            pid: pid,
            gen: context.gen,
            since: context.now,
            born: false,
            identified: 1
          )
          |> identify(identity, context)

        # At the first sweep there is nothing to take a difference
        # against. After it, what was not there before was started since.
        work = if context.first, do: 0, else: reductions
        row = record(row, context, reductions, memory, queue, work)
        :ets.insert(context.table, row)

        %{found | new: [pid | found.new]}
        |> count(row, figures, work)
    end
  end

  defp seen(row, found, context, {reductions, memory, queue, name} = figures) do
    tracked(pid: pid, swept: swept, since: since, identified: identified) = row
    age = context.now - since

    work =
      cond do
        swept -> max(reductions - tracked(row, :reductions), 0)
        context.first -> 0
        true -> reductions
      end

    # Asked what it is when a sweep first finds it alive, and once more
    # when it is old enough for series: by then it has said what it has to
    # say of itself.
    asked =
      cond do
        identified == 0 -> reidentify(row, pid, context, 1)
        identified == 1 and age >= context.min_age -> reidentify(row, pid, context, 2)
        true -> row
      end

    asked = if tracked(asked, :name) == name, do: asked, else: rename(asked, name)

    row =
      if asked == row do
        :ets.update_element(context.table, pid, [
          {tracked(:gen) + 1, context.gen},
          {tracked(:swept) + 1, context.now},
          {tracked(:reductions) + 1, reductions},
          {tracked(:memory) + 1, memory},
          {tracked(:peak_memory) + 1, max(memory, tracked(row, :peak_memory))},
          {tracked(:queue) + 1, queue},
          {tracked(:rate) + 1, rate(work, context)}
        ])

        row
      else
        changed = record(asked, context, reductions, memory, queue, work)
        :ets.insert(context.table, changed)
        changed
      end

    found
    |> count(row, figures, work)
    |> series(row, figures, work, age, context)
  end

  defp record(row, context, reductions, memory, queue, work) do
    tracked(row,
      gen: context.gen,
      swept: context.now,
      reductions: reductions,
      memory: memory,
      peak_memory: max(memory, tracked(row, :peak_memory)),
      queue: queue,
      rate: rate(work, context)
    )
  end

  defp rate(_work, %{seconds: nil}), do: nil
  defp rate(work, %{seconds: seconds}), do: Batch.rate(work, 0, seconds)

  defp reidentify(row, pid, context, identified) do
    known = %Identity{call: tracked(row, :call), caller: tracked(row, :caller)}

    case Identity.read(pid, known) do
      nil -> row
      identity -> row |> identify(identity, context) |> tracked(identified: identified)
    end
  end

  # What asking a process says of it. Whom it was started by and for is
  # taken from asking only if it was not heard.
  defp identify(row, %Identity{} = identity, context) do
    base = Identity.group(%{identity | name: nil})

    tracked(row,
      parent: tracked(row, :parent) || identity.parent,
      caller: tracked(row, :caller) || identity.caller,
      call: identity.call,
      base: base,
      group: Identity.group(identity),
      path: Identity.path(identity),
      name: Identity.name(identity),
      app: Map.get(context.masters, identity.group_leader) || tracked(row, :app),
      starter: Identity.starter?(identity, context.options.trace_roots)
    )
  end

  defp count(found, row, {_reductions, memory, queue, _name}, work) do
    tracked(group: group, app: app) = row

    add = fn total ->
      %{
        total
        | processes: total.processes + 1,
          memory: total.memory + memory,
          work: total.work + work,
          queue: total.queue + queue,
          longest: max(total.longest, queue)
      }
    end

    none = %{processes: 0, memory: 0, work: 0, queue: 0, longest: 0}

    %{
      found
      | groups: Map.update(found.groups, group, add.(none), add),
        apps: Map.update(found.apps, app || "none", add.(none), add),
        processes: found.processes + 1,
        accounted: found.accounted + work
    }
  end

  ## Series for one process

  defp series(found, tracked(admitted: true) = row, figures, work, _age, context),
    do: %{found | batch: report_process(found.batch, row, figures, work, context)}

  defp series(found, _row, _figures, _work, _age, %{room: false}), do: found

  defp series(found, _row, _figures, _work, age, %{min_age: min_age}) when age < min_age,
    do: found

  defp series(found, row, {_reductions, memory, queue, name} = figures, work, _age, context) do
    options = context.options
    share = context.vm_delta && Batch.pct(work, context.vm_delta)

    cond do
      # Those with a name before those without, and the larger first.
      name ->
        candidate(found, {1, memory}, row, figures, work)

      memory >= options.notable_memory or queue >= options.notable_queue or
          (share && share >= options.notable_work) ->
        candidate(found, {0, memory}, row, figures, work)

      true ->
        found
    end
  end

  defp candidate(found, weight, row, figures, work),
    do: %{found | candidates: [{weight, row, figures, work} | found.candidates]}

  defp admit(state, found, context) do
    room = state.options.max_processes - state.admitted

    admitted =
      found.candidates
      |> Enum.sort_by(fn {weight, tracked(pid: pid), _, _} -> {weight, pid} end, :desc)
      |> Enum.take(max(room, 0))

    batch =
      Enum.reduce(admitted, found.batch, fn {_weight, tracked(pid: pid) = row, figures, work},
                                            batch ->
        :ets.update_element(state.table, pid, {tracked(:admitted) + 1, true})
        report_process(batch, row, figures, work, context)
      end)

    {%{state | admitted: state.admitted + length(admitted)}, batch}
  end

  defp report_process(batch, row, {reductions, memory, queue, name}, work, context) do
    tracked(pid: pid, group: group, app: app) = row

    labels = [
      {"proc", Identity.proc(name || group, pid)},
      {"pid", Identity.pid_text(pid)},
      {"group", group},
      {"app", app || "none"}
    ]

    batch
    |> Batch.push("beam_proc_reductions_per_sec", labels, rate(work, context))
    |> Batch.push("beam_proc_work_pct", labels, share(work, context))
    |> Batch.push("beam_proc_reductions", labels, reductions)
    |> Batch.push("beam_proc_memory_bytes", labels, memory)
    |> Batch.push("beam_proc_message_queue_len", labels, queue)
  end

  defp share(_work, %{vm_delta: nil}), do: nil
  defp share(work, %{vm_delta: delta}), do: Batch.pct(work, delta)

  ## Those that are gone

  # With the VM telling of each end, a process found gone waits one sweep
  # for word of it, in case the message is still on its way. If none
  # comes, it was lost, and the process is accounted as gone.
  defp vanished(state, now) do
    before = if state.listening, do: state.gen - 1, else: state.gen

    gone =
      :ets.select(state.table, [{tracked(gen: :"$1", _: :_), [{:<, :"$1", before}], [:"$_"]}])

    described = Enum.map(gone, &describe(state, &1, Ending.unknown(), now, :sampled))

    state =
      gone
      |> Enum.zip(described)
      |> Enum.reduce(state, fn {row, ended}, state -> state |> forget(row) |> tally(ended) end)

    {state, described}
  end

  ## Totals

  # A name that has a place is reported at every reading, as nothing
  # while it has nothing, so that the last sample of a pool that has
  # emptied does not say it is as full as it last was.
  defp report_groups(state, batch, groups, context) do
    tallies = state.tallies.groups
    places = Admission.members(state.groups)
    names = Enum.uniq(Map.keys(groups) ++ Map.keys(tallies) ++ places)

    by_report =
      Enum.group_by(names, fn name ->
        if Admission.member?(state.groups, name), do: name, else: "other"
      end)

    # Once there has been an `other`, there is one at every reading.
    others = state.others or is_map_key(by_report, "other")
    by_report = if others, do: Map.put_new(by_report, "other", []), else: by_report

    batch =
      by_report
      |> Enum.sort()
      |> Enum.reduce(batch, fn {reported_as, names}, batch ->
        report_total(
          batch,
          "beam_group",
          [{"group", reported_as}],
          names,
          groups,
          tallies,
          context
        )
      end)

    {%{state | others: others}, batch}
  end

  defp report_apps(state, batch, apps, by_owner, context) do
    tallies = state.tallies.apps
    tables = tables_by_app(state, by_owner)
    present = Enum.uniq(Map.keys(apps) ++ Map.keys(tallies) ++ Map.keys(tables))
    admission = Admission.reading(state.apps, Enum.map(present, &{&1, 0}))

    batch =
      admission
      |> Admission.members()
      |> Enum.sort()
      |> Enum.reduce(batch, fn name, batch ->
        labels = [{"app", name}]

        batch
        |> report_total("beam_app", labels, [name], apps, tallies, context)
        |> Batch.push("beam_app_ets_bytes", labels, Map.get(tables, name, 0))
      end)

    {%{state | apps: admission}, batch}
  end

  defp tables_by_app(state, by_owner) do
    Enum.reduce(by_owner, %{}, fn {owner, bytes}, tables ->
      app =
        case :ets.lookup(state.table, owner) do
          [tracked(app: app)] when not is_nil(app) -> app
          _ -> "none"
        end

      Map.update(tables, app, bytes, &(&1 + bytes))
    end)
  end

  defp report_total(batch, prefix, labels, names, totals, tallies, context) do
    total =
      Enum.reduce(names, %{processes: 0, memory: 0, work: 0, queue: 0, longest: 0}, fn name,
                                                                                       sum ->
        case totals do
          %{^name => total} ->
            %{
              processes: sum.processes + total.processes,
              memory: sum.memory + total.memory,
              work: sum.work + total.work,
              queue: sum.queue + total.queue,
              longest: max(sum.longest, total.longest)
            }

          _ ->
            sum
        end
      end)

    tallied = fn what ->
      Enum.reduce(names, 0, &(&2 + (tallies |> Map.get(&1, %{}) |> Map.get(what, 0))))
    end

    per_second = fn count -> context.seconds && Batch.rate(count, 0, context.seconds) end

    batch
    |> Batch.push("#{prefix}_processes", labels, total.processes)
    |> Batch.push("#{prefix}_memory_bytes", labels, total.memory)
    |> Batch.push("#{prefix}_reductions_per_sec", labels, rate(total.work, context))
    |> Batch.push("#{prefix}_work_pct", labels, share(total.work, context))
    |> Batch.push("#{prefix}_message_queue_len", labels, total.queue)
    |> Batch.push("#{prefix}_message_queue_max", labels, total.longest)
    |> Batch.push("#{prefix}_spawns_per_sec", labels, per_second.(tallied.(:spawns)))
    |> Batch.push("#{prefix}_exits_per_sec", labels, per_second.(tallied.(:exits)))
    |> Batch.push("#{prefix}_failures_per_sec", labels, per_second.(tallied.(:failures)))
  end

  ## For those who look

  @doc """
  What is known of a process that is running, for a remark on it. `nil` if
  it is not tracked.
  """
  @spec known(t() | atom() | :ets.tid(), pid()) :: map() | nil
  def known(%__MODULE__{table: table}, pid), do: known(table, pid)

  def known(table, pid) when is_pid(pid) do
    case :ets.lookup(table, pid) do
      [row] -> Tracked.to_map(row)
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Every process that is tracked, as it was at the last sweep, for
  `TimelessBeamAcct.top/1`. Read from the table, by whoever asks.

  `vm_rate` is the node's reductions a second, which each process's work
  is a share of.

  A node may have a hundred thousand processes, and whoever draws it
  wants the first few of them:

    * `:most`: only so many by what they do, so many by what they hold,
      and so many by what they have waiting
    * `:group`, `:app`: only those of a group, or of an application
  """
  @spec snapshot(atom() | :ets.tid(), number() | nil, keyword()) :: [map()]
  def snapshot(table, vm_rate \\ nil, opts \\ []) do
    now = mono()

    for row <- chosen(table, opts[:group], opts[:app], opts[:most]) do
      tracked(pid: pid, name: name, group: group, rate: rate) = row

      %{
        pid: Identity.pid_text(pid),
        name: name || group,
        group: group,
        app: tracked(row, :app) || "none",
        registered: not is_nil(name),
        age_seconds: seconds(now - tracked(row, :since)),
        age_known: tracked(row, :born),
        reductions: tracked(row, :reductions),
        reductions_per_sec: rate,
        work_pct: rate && vm_rate && Batch.pct(rate, vm_rate),
        memory_bytes: tracked(row, :memory),
        message_queue_len: tracked(row, :queue)
      }
    end
  rescue
    ArgumentError -> []
  end

  # The rows that were asked for, of those a sweep has seen.
  defp chosen(table, nil, nil, nil) do
    for row <- :ets.tab2list(table), tracked(row, :swept) != nil, do: row
  end

  # Four figures of each row are read, and not the row: the rows of the
  # few that are chosen are read after.
  defp chosen(table, group, app, most) do
    figures =
      :ets.foldl(
        fn row, figures ->
          if tracked(row, :swept) != nil and
               (group == nil or tracked(row, :group) == group) and
               (app == nil or (tracked(row, :app) || "none") == app) do
            tracked(pid: pid, rate: rate, memory: memory, queue: queue) = row
            [{pid, rate || -1, memory, queue} | figures]
          else
            figures
          end
        end,
        [],
        table
      )

    pids =
      case most do
        nil ->
          Enum.map(figures, &elem(&1, 0))

        most ->
          for by <- 1..3,
              {pid, _, _, _} <- figures |> Enum.sort_by(&elem(&1, by), :desc) |> Enum.take(most),
              uniq: true,
              do: pid
      end

    for pid <- pids, row <- :ets.lookup(table, pid), do: row
  end

  ## Applications

  # The process at the head of each running application. Every process of
  # the application has it as its group leader.
  defp masters do
    for [app, master] <- :ets.match(:ac_tab, {{:application_master, :"$1"}, :"$2"}),
        into: %{},
        do: {master, Identity.text(app)}
  rescue
    ArgumentError -> %{}
  end

  ## Time

  @doc "A monotonic time, in native units, as epoch microseconds."
  @spec epoch_us(integer()) :: integer()
  def epoch_us(mono),
    do: System.convert_time_unit(mono + :erlang.time_offset(), :native, :microsecond)

  defp mono, do: :erlang.monotonic_time()
  defp seconds(native), do: native / System.convert_time_unit(1, :second, :native)
  defp native(seconds), do: round(seconds * System.convert_time_unit(1, :second, :native))
end
