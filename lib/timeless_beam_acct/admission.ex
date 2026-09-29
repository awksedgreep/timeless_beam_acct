defmodule TimelessBeamAcct.Admission do
  @moduledoc """
  Which names are reported as themselves, when there is room for only so
  many. The rest are reported together, as `other`.

  A name that has a place keeps it. If the largest at each reading were
  chosen afresh, a name near the edge would be a line on one reading and
  part of `other` on the next, and neither line would mean anything.

  A name that is absent keeps its place for a few readings: a pool between
  two jobs has no processes, and is the same pool when it has them again.
  """

  @type name :: term()
  @type t :: %__MODULE__{
          capacity: non_neg_integer(),
          linger: non_neg_integer(),
          members: %{name() => non_neg_integer()}
        }

  # `members` holds, for each name with a place, the number of readings it
  # has been absent from.
  defstruct capacity: 0, linger: 6, members: %{}

  @doc """
  Room for `capacity` names. An absent name keeps its place for `:linger`
  readings.
  """
  @spec new(non_neg_integer(), keyword()) :: t()
  def new(capacity, opts \\ []) when is_integer(capacity) and capacity >= 0,
    do: %__MODULE__{capacity: capacity, linger: Keyword.get(opts, :linger, 6)}

  @doc """
  Take a reading: the names present, each with its weight.

  Places left over are given to the heaviest of the names without one.
  """
  @spec reading(t(), Enumerable.t({name(), number()})) :: t()
  def reading(%__MODULE__{} = admission, present) do
    present = Map.new(present)

    members =
      for {name, absent} <- admission.members,
          absent = if(is_map_key(present, name), do: 0, else: absent + 1),
          absent <= admission.linger,
          into: %{},
          do: {name, absent}

    room = admission.capacity - map_size(members)

    admitted =
      if room > 0 do
        present
        |> Enum.reject(fn {name, _weight} -> is_map_key(members, name) end)
        # By name among equals, so that the same reading admits the same names.
        |> Enum.sort_by(fn {name, weight} -> {-weight, name} end)
        |> Enum.take(room)
        |> Map.new(fn {name, _weight} -> {name, 0} end)
      else
        %{}
      end

    %{admission | members: Map.merge(members, admitted)}
  end

  @doc "Whether a name is reported as itself."
  @spec member?(t(), name()) :: boolean()
  def member?(%__MODULE__{members: members}, name), do: is_map_key(members, name)

  @doc "How many names have a place."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{members: members}), do: map_size(members)
end
