defmodule TimelessBeamAcct.Watch.State do
  @moduledoc """
  What is being looked at: which moment, which view, which row.

  The keys are those of `timeless-acct watch`, and do what they do there.
  A key changes what is looked at and says what it changed, which is what
  there is then to do about it:

  | | |
  |---|---|
  | `:nothing` | |
  | `:view` | how it is drawn |
  | `:moment` | which moment, or which part of it: there is reading to do |
  | `:open` | the picked row is to be opened |
  | `:go` | the moment of the picked row is to be gone to |
  """

  alias TimelessBeamAcct.Clock
  alias TimelessBeamAcct.Watch.{Data, Terminal}

  @tabs [:groups, :processes, :jobs, :exits]
  @sorts [:work, :memory, :queue, :name]

  # The stretches of time the timeline can show.
  @windows {600.0, 3600.0, 6 * 3600.0, 86_400.0, 7 * 86_400.0}

  @type tab :: :groups | :processes | :jobs | :exits
  @type sort :: :work | :memory | :queue | :name
  @type changed :: :nothing | :view | :moment | :open | :go
  @type range :: {number(), number()} | nil

  @type t :: %__MODULE__{
          tab: tab(),
          sort: sort(),
          at: float() | nil,
          selected: %{tab() => non_neg_integer() | :last},
          filter: String.t(),
          typing: boolean(),
          help: boolean(),
          quit: boolean(),
          apps: boolean(),
          within: {:group | :app, String.t()} | nil,
          going: String.t() | nil,
          inspecting: boolean(),
          message: String.t() | nil,
          window: non_neg_integer(),
          step: float()
        }

  defstruct tab: :groups,
            sort: :work,
            # The moment looked at, in epoch seconds; `nil` is now.
            at: nil,
            # The row picked in each view.
            selected: %{groups: 0, processes: 0, jobs: 0, exits: 0},
            filter: "",
            # Whether keys are going into the filter.
            typing: false,
            help: false,
            quit: false,
            # Whether the first view is of applications, and not of groups.
            apps: false,
            # The group, or the application, whose processes are the only
            # ones shown.
            within: nil,
            # A moment being typed, to go to.
            going: nil,
            # Whether what is known of the picked row is on the screen.
            inspecting: false,
            # Something to say, until the next key.
            message: nil,
            # Which of the stretches the timeline shows.
            window: 1,
            # Seconds between the store's samples: the smallest step in time.
            step: 10.0

  @spec new(float() | nil, number()) :: t()
  def new(at, step), do: %__MODULE__{at: at, step: max(step / 1, 1.0)}

  @spec tabs() :: [tab()]
  def tabs, do: @tabs

  @spec title(tab()) :: String.t()
  def title(:groups), do: "Groups"
  def title(:processes), do: "Processes"
  def title(:jobs), do: "Jobs"
  def title(:exits), do: "Exits"

  @spec sort_title(sort()) :: String.t()
  def sort_title(sort), do: Atom.to_string(sort)

  @doc """
  The timeline drawn out until it shows a stretch of at least `span`
  seconds, as far as it can be: what a recording is opened with.
  """
  @spec fit(t(), number() | nil) :: t()
  def fit(%__MODULE__{} = state, nil), do: state

  def fit(%__MODULE__{} = state, span) do
    last = tuple_size(@windows) - 1
    index = Enum.find(0..last, last, &(elem(@windows, &1) >= span))
    %{state | window: index}
  end

  @doc "How long a stretch the timeline shows, in seconds."
  @spec window(t()) :: float()
  def window(%__MODULE__{window: window}), do: elem(@windows, window)

  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{at: at}), do: at == nil

  @doc "Whether only some of what there is, is wanted."
  @spec looking?(t()) :: boolean()
  def looking?(%__MODULE__{filter: filter}), do: filter != ""

  @doc "The row picked in the view that is shown."
  @spec selected(t()) :: non_neg_integer()
  def selected(%__MODULE__{selected: selected, tab: tab}) do
    case Map.fetch!(selected, tab) do
      :last -> 1_000_000_000
      row -> row
    end
  end

  @doc "Keep the picked row on a row there is."
  @spec clamp(t(), non_neg_integer()) :: t()
  def clamp(%__MODULE__{} = state, rows),
    do: pick(state, min(selected(state), max(rows - 1, 0)))

  defp pick(state, row), do: %{state | selected: Map.put(state.selected, state.tab, row)}

  defp select(state, by), do: pick(state, max(selected(state) + by, 0))

  @doc """
  Go to a moment, as near as the store holds one. `range` is the first and
  last moments it holds.
  """
  @spec go_to(t(), number(), range()) :: t()
  def go_to(%__MODULE__{} = state, _at, nil), do: state

  def go_to(%__MODULE__{} = state, at, {first, last}) do
    at = Float.floor(at / state.step) * state.step
    # What ended then is what ended last, up to then.
    pick(%{state | at: if(at > last, do: nil, else: max(at, first / 1))}, 0)
  end

  # Move through time by `seconds`.
  #
  # Going back from now lands on what the store holds, and not on the
  # moment that many seconds ago: what the collector has read and the sink
  # has not yet written is not in the store. Going forward past the last
  # moment stored is going back to now.
  defp shift(state, _seconds, nil), do: {state, :nothing}

  defp shift(state, seconds, {first, last}) do
    from = state.at || last + state.step
    to = Float.floor((from + seconds) / state.step) * state.step
    moved = if to > last, do: nil, else: max(to, first / 1)

    if moved == state.at,
      do: {state, :nothing},
      else: {%{state | at: moved}, :moment}
  end

  @doc "Show the processes of one group, or of one application, and nothing else."
  @spec enter(t(), {:group | :app, String.t()}) :: t()
  def enter(%__MODULE__{} = state, within) do
    # What picked the group out is not what picks its processes out.
    %{state | within: within, filter: "", tab: :processes}
    |> pick(0)
  end

  # Go to a moment that was typed.
  defp go(state, text, now, range) do
    case {Clock.parse(text, now), range} do
      {{:error, why}, _} ->
        {%{state | message: why}, :view}

      {_, nil} ->
        {%{state | message: "There is nothing stored to go to."}, :view}

      {{:ok, to}, {first, last}} ->
        at = Float.floor(to / state.step) * state.step

        cond do
          at > last ->
            {%{state | at: nil}, :moment}

          at < first ->
            {%{state | at: first / 1, message: "The store begins at #{Clock.format(first)}."},
             :moment}

          true ->
            {%{state | at: at}, :moment}
        end
    end
  end

  @doc """
  A key. `now` is epoch seconds; `range` is the first and last moments
  the store holds.
  """
  @spec key(t(), Terminal.key(), number(), range()) :: {t(), changed()}
  def key(%__MODULE__{} = state, :ctrl_c, _now, _range), do: {%{state | quit: true}, :view}

  def key(%__MODULE__{} = state, key, now, range),
    do: pressed(%{state | message: nil}, key, now, range)

  # A moment is being typed.
  defp pressed(%{going: text} = state, key, now, range) when is_binary(text) do
    case key do
      :enter ->
        state = %{state | going: nil}
        if String.trim(text) == "", do: {state, :view}, else: go(state, text, now, range)

      :esc ->
        {%{state | going: nil}, :view}

      :backspace ->
        {%{state | going: String.slice(text, 0..-2//1)}, :view}

      {:char, char} ->
        {%{state | going: text <> char}, :view}

      _ ->
        {state, :nothing}
    end
  end

  # What is wanted is being typed.
  defp pressed(%{typing: true} = state, key, _now, _range) do
    case key do
      # What is wanted has been said: there is reading to do, for what
      # matches and is further back than what is on the screen.
      :enter -> {%{state | typing: false}, :moment}
      :esc -> {%{state | typing: false, filter: ""}, :moment}
      :backspace -> {%{state | filter: String.slice(state.filter, 0..-2//1)}, :view}
      {:char, char} -> {%{state | filter: state.filter <> char}, :view}
      _ -> {state, :nothing}
    end
  end

  # Something is drawn over the rest: any key puts it away.
  defp pressed(%{help: help, inspecting: inspecting} = state, _key, _now, _range)
       when help or inspecting,
       do: {%{state | help: false, inspecting: false}, :view}

  defp pressed(state, key, _now, range) do
    {minute, hour} = {60.0, 3600.0}

    case key do
      # Out of a group before out of the program.
      key when key in [:esc, :backspace] and state.within != nil ->
        {%{state | within: nil, tab: :groups}, :moment}

      :backspace ->
        {state, :nothing}

      key when key in [:esc, {:char, "q"}] ->
        {%{state | quit: true}, :moment}

      key when key in [{:char, "?"}, {:char, "h"}] ->
        {%{state | help: true}, :moment}

      :enter ->
        {state, :open}

      {:char, "m"} ->
        {state, :go}

      {:char, char} when char in ["-", "_"] ->
        if state.window + 1 == tuple_size(@windows),
          do: {state, :nothing},
          else: {%{state | window: state.window + 1}, :moment}

      {:char, char} when char in ["+", "="] ->
        if state.window == 0,
          do: {state, :nothing},
          else: {%{state | window: state.window - 1}, :moment}

      {:char, "t"} ->
        {%{state | going: ""}, :view}

      {:shift, :left} ->
        shift(state, -minute, range)

      {:shift, :right} ->
        shift(state, minute, range)

      :left ->
        shift(state, -state.step, range)

      :right ->
        shift(state, state.step, range)

      {:char, ","} ->
        shift(state, -minute, range)

      {:char, "."} ->
        shift(state, minute, range)

      {:char, "<"} ->
        shift(state, -10 * minute, range)

      {:char, ">"} ->
        shift(state, 10 * minute, range)

      {:char, "["} ->
        shift(state, -hour, range)

      {:char, "]"} ->
        shift(state, hour, range)

      {:char, "{"} ->
        shift(state, -24 * hour, range)

      {:char, "}"} ->
        shift(state, 24 * hour, range)

      :home ->
        case range do
          {first, _last} when first / 1 != state.at -> {%{state | at: first / 1}, :moment}
          _ -> {state, :nothing}
        end

      key when key in [:end, {:char, "l"}] ->
        if state.at == nil, do: {state, :nothing}, else: {%{state | at: nil}, :moment}

      key when key in [:tab, :backtab] ->
        count = length(@tabs)
        step = if key == :tab, do: 1, else: count - 1
        index = Enum.find_index(@tabs, &(&1 == state.tab))
        {%{state | tab: Enum.at(@tabs, rem(index + step, count))}, :moment}

      {:char, char} when char in ["1", "2", "3", "4"] ->
        {%{state | tab: Enum.at(@tabs, String.to_integer(char) - 1)}, :moment}

      key when key in [:down, {:char, "j"}] ->
        {select(state, 1), :moment}

      key when key in [:up, {:char, "k"}] ->
        {select(state, -1), :moment}

      :page_down ->
        {select(state, 10), :moment}

      :page_up ->
        {select(state, -10), :moment}

      {:char, "g"} ->
        {pick(state, 0), :moment}

      {:char, "G"} ->
        {pick(state, :last), :moment}

      {:char, "s"} ->
        index = Enum.find_index(@sorts, &(&1 == state.sort))
        state = %{state | sort: Enum.at(@sorts, rem(index + 1, length(@sorts)))}
        {pick(state, 0), :moment}

      {:char, "/"} ->
        {%{state | typing: true, filter: ""}, :moment}

      {:char, "a"} ->
        {pick(%{state | apps: not state.apps}, 0), :moment}

      _ ->
        {state, :nothing}
    end
  end

  ## The rows of a view

  @doc "Whether something is wanted: by any of what is said of it."
  @spec wants?(t(), [String.t() | nil]) :: boolean()
  def wants?(%__MODULE__{filter: ""}, _about), do: true

  def wants?(%__MODULE__{filter: filter}, about) do
    filter = String.downcase(filter)
    Enum.any?(about, &(is_binary(&1) and String.contains?(String.downcase(&1), filter)))
  end

  @doc """
  The groups to show, in the order to show them: or the applications,
  where those are what was asked for.
  """
  @spec groups(t(), Data.t()) :: [Data.group()]
  def groups(%__MODULE__{} = state, %Data{} = snapshot) do
    rows = if state.apps, do: snapshot.apps, else: snapshot.groups

    rows
    |> Enum.filter(&wants?(state, [&1.name]))
    |> order(state.sort, fn group ->
      case state.sort do
        :work -> group.work
        :memory -> group.memory
        :queue -> group.queue
        :name -> nil
      end
    end)
  end

  @doc "The processes to show, in the order to show them."
  @spec processes(t(), Data.t()) :: [Data.process()]
  def processes(%__MODULE__{} = state, %Data{} = snapshot) do
    snapshot.processes
    |> Enum.filter(fn process ->
      case state.within do
        nil -> true
        {:group, group} -> process.group == group
        {:app, app} -> process.app == app
      end
    end)
    |> Enum.filter(&wants?(state, [&1.name, &1.app, &1.pid]))
    |> order(state.sort, fn process ->
      case state.sort do
        :work -> process.work
        :memory -> process.memory
        :queue -> process.queue
        :name -> nil
      end
    end)
  end

  # The largest first, and what has no figure last. The rows come in by
  # name, and equals are left that way: the order on the screen does not
  # change when nothing has.
  defp order(rows, :name, _figure), do: rows

  defp order(rows, _sort, figure) do
    rows
    |> Enum.with_index()
    |> Enum.sort_by(fn {row, index} ->
      case figure.(row) do
        nil -> {1, 0, index}
        value -> {0, -value, index}
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end
end
