defmodule TimelessBeamAcct.Collect.Ets do
  @moduledoc """
  Tables: what they hold, and what they cost.

  A table's memory is on no process's heap, so a sweep of the processes
  does not find it. It is accounted here, and handed to the sweep by the
  pid of each table's owner, so that an application can be charged for
  the tables its processes own.

  | metric | is |
  |---|---|
  | `beam_ets_memory_bytes` | memory of the tables of that name |
  | `beam_ets_objects` | objects in them |
  | `beam_ets_tables` | how many tables have that name |

  Label: `table`.

  ## A table is reported by its name

  Tables of one name are added together. A name need not be unique: only
  a named table's is, and a library that makes a table for each connection
  gives them all the same name. Under their identifiers each would be a
  new set of series, and would leave it behind when the connection closed;
  under their name, a thousand of them are one line. This is the decision
  the system collector makes for processes of one command name.

  The name is written as Elixir writes it, without the colon of an atom:
  `:my_table` is `my_table`, and `MyApp.Cache` is `MyApp.Cache`.

  ## Only so many names are reported

  At most `:max_tables` names are reported as themselves, the ones with
  the most memory, and a name that has a place keeps it (see
  `TimelessBeamAcct.Admission`). The rest are added together and reported
  as `table="other"`, so that the series add up to all there is. A table
  whose own name is `other` is counted there too: two series cannot share
  a name and a label.

  A name that has a place is reported at every reading, as nothing while
  there is no table of that name, and so is `other` once there has been
  one. A reader takes the last sample of a series as its value, and the
  last sample of a table that was deleted would otherwise say that it
  holds what it last held.

  ## Reading

  Each table is read with four calls of `:ets.info/2`. One call of
  `:ets.info/1` returns those four among its fifteen items, and costs twice
  as much: 190 ns for a table against 94 ns, measured with 3000 tables.

  A table can be deleted between `:ets.all/0` and the reading of it. Then
  there is nothing to report of it, and it is left out.
  """

  alias TimelessBeamAcct.{Admission, Batch, Options}

  @other [{"table", "other"}]

  @typedoc "One table: its name, its memory in bytes, its objects, and its owner."
  @type table ::
          {name :: atom(), bytes :: non_neg_integer(), objects :: non_neg_integer(),
           owner :: pid()}

  @type state :: %__MODULE__{
          admission: Admission.t(),
          labels: %{atom() => Batch.labels()},
          others: boolean()
        }

  # `others` is whether `other` has been reported, and so is from then on.
  defstruct admission: nil, labels: %{}, others: false

  @doc "A collector with room for `options.max_tables` names."
  @spec new(Options.t()) :: state()
  def new(%Options{} = options),
    do: %__MODULE__{admission: Admission.new(options.max_tables)}

  @doc """
  Read every table, and add this instant's samples to the batch.

  Also returns the bytes of table memory by the pid of the tables' owner,
  over all tables, whether reported by name or not.
  """
  @spec collect(state(), Batch.t()) ::
          {state(), Batch.t(), by_owner :: %{pid() => non_neg_integer()}}
  def collect(%__MODULE__{} = state, %Batch{} = batch), do: report(state, batch, read())

  @doc "There is nothing to give back."
  @spec close(state()) :: :ok
  def close(%__MODULE__{}), do: :ok

  @doc """
  The samples of one reading of the tables, and their memory by owner.
  """
  @spec report(state(), Batch.t(), [table()]) ::
          {state(), Batch.t(), by_owner :: %{pid() => non_neg_integer()}}
  def report(%__MODULE__{} = state, %Batch{} = batch, tables) when is_list(tables) do
    {by_name, by_owner} =
      Enum.reduce(tables, {%{}, %{}}, fn {name, bytes, objects, owner}, {by_name, by_owner} ->
        by_name =
          case by_name do
            %{^name => {all_bytes, all_objects, count}} ->
              %{by_name | name => {all_bytes + bytes, all_objects + objects, count + 1}}

            %{} ->
              Map.put(by_name, name, {bytes, objects, 1})
          end

        {by_name, Map.update(by_owner, owner, bytes, &(&1 + bytes))}
      end)

    admission =
      Admission.reading(
        state.admission,
        for({name, {bytes, _, _}} <- by_name, name != :other, do: {name, bytes})
      )

    labels =
      for name <- Admission.members(admission), into: %{} do
        {name, Map.get_lazy(state.labels, name, fn -> [{"table", label(name)}] end)}
      end

    other =
      Enum.reduce(by_name, {0, 0, 0}, fn {name, {bytes, objects, count}}, {b, o, c} = other ->
        if is_map_key(labels, name), do: other, else: {b + bytes, o + objects, c + count}
      end)

    # A name that has a place and no table is reported as nothing.
    batch =
      labels
      |> Enum.map(fn {name, label} -> {label, Map.get(by_name, name, {0, 0, 0})} end)
      |> Enum.sort()
      |> Enum.reduce(batch, fn {label, sums}, batch -> push(batch, label, sums) end)

    others = state.others or elem(other, 2) > 0
    batch = if others, do: push(batch, @other, other), else: batch

    {%{state | admission: admission, labels: labels, others: others}, batch, by_owner}
  end

  defp push(batch, labels, {bytes, objects, count}) do
    batch
    |> Batch.push("beam_ets_memory_bytes", labels, bytes)
    |> Batch.push("beam_ets_objects", labels, objects)
    |> Batch.push("beam_ets_tables", labels, count)
  end

  @doc """
  A table's name as a label: as the name of a process is written.
  """
  @spec label(atom()) :: String.t()
  def label(name) when is_atom(name), do: TimelessBeamAcct.Identity.text(name)

  @doc false
  @spec read([:ets.table()]) :: [table()]
  def read(tables \\ :ets.all()) do
    wordsize = :erlang.system_info(:wordsize)
    read(tables, wordsize, [])
  end

  defp read([table | rest], wordsize, read) do
    # The name is read first, and is known to be a name and not the
    # `:undefined` of a table that is gone by the table still being there
    # for the calls after it: a table may be named `:undefined`.
    with name when is_atom(name) <- :ets.info(table, :name),
         words when is_integer(words) <- :ets.info(table, :memory),
         objects when is_integer(objects) <- :ets.info(table, :size),
         owner when is_pid(owner) <- :ets.info(table, :owner) do
      read(rest, wordsize, [{name, words * wordsize, objects, owner} | read])
    else
      _ -> read(rest, wordsize, read)
    end
  end

  defp read([], _wordsize, read), do: read
end
