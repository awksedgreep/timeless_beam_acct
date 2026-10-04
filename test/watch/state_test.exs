defmodule TimelessBeamAcct.Watch.StateTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.Watch.State
  alias TimelessBeamAcct.Watched

  @range {1000.0, 5000.0}
  @now 5030.0

  defp key(state, key, range \\ @range), do: State.key(state, key, @now, range)

  # Each letter as a key, and what the last of them changed.
  defp press(state, text, range \\ @range) do
    text
    |> String.graphemes()
    |> Enum.reduce({state, :nothing}, fn char, {state, _changed} ->
      key(state, {:char, char}, range)
    end)
  end

  defp pressed(state, text), do: state |> press(text) |> elem(0)

  test "going back from now lands on the last moment stored" do
    state = State.new(nil, 10)
    assert State.live?(state)

    assert {state, :moment} = key(state, :left)
    assert state.at == 5000.0
    {state, _} = key(state, :left)
    assert state.at == 4990.0
    state = pressed(state, ",")
    assert state.at == 4930.0
    state = pressed(state, "<")
    assert state.at == 4330.0
    state = pressed(state, "[")
    # No further than the first.
    assert state.at == 1000.0
    assert {_state, :nothing} = press(state, "[")
  end

  test "going forward past the last moment stored is going back to now" do
    {state, _} = key(State.new(4990.0, 10), :right)
    assert state.at == 5000.0
    assert {state, :moment} = key(state, :right)
    assert State.live?(state)
    assert {_state, :nothing} = key(state, :right)

    state = pressed(%{state | at: 2000.0}, "l")
    assert State.live?(state)
    {state, _} = key(state, :home)
    assert state.at == 1000.0
    assert {_state, :nothing} = key(state, :home)
    {state, _} = key(state, :end)
    assert State.live?(state)
  end

  test "a moment is one the store sampled" do
    {state, _} = key(State.new(4995.0, 10), :left)
    assert state.at == 4980.0
    {state, _} = key(state, {:shift, :left})
    assert state.at == 4920.0
    {state, _} = key(state, {:shift, :right})
    assert state.at == 4980.0
    state = pressed(state, "}")
    assert State.live?(state)
    state = pressed(state, "{")
    assert state.at == 1000.0
  end

  test "with nothing stored there is only now" do
    state = State.new(nil, 10)
    assert {_state, :nothing} = key(state, :left, nil)
    assert {_state, :nothing} = key(state, :home, nil)
    assert {state, :nothing} = press(state, "<", nil)
    assert State.live?(state)
  end

  test "views are stepped through and jumped to" do
    state = State.new(nil, 10)
    assert state.tab == :groups
    {state, :moment} = key(state, :tab)
    assert state.tab == :processes
    state = pressed(state, "4")
    assert state.tab == :exits
    {state, _} = key(state, :tab)
    assert state.tab == :groups
    {state, _} = key(state, :backtab)
    assert state.tab == :exits
    assert pressed(state, "3").tab == :jobs
  end

  test "each view keeps its own selection" do
    state = pressed(State.new(nil, 10), "jjj")
    assert State.selected(state) == 3
    state = pressed(state, "2")
    assert State.selected(state) == 0
    state = pressed(state, "j1")
    assert State.selected(state) == 3
    state = pressed(state, "kkkkk")
    assert State.selected(state) == 0

    {state, _} = key(state, :page_down)
    assert State.selected(state) == 10
    {state, _} = key(state, :page_up)
    {state, _} = key(state, :down)
    {state, _} = key(state, :up)
    assert State.selected(state) == 0

    state = state |> pressed("G") |> State.clamp(7)
    assert State.selected(state) == 6
    assert State.selected(State.clamp(state, 0)) == 0
    assert State.selected(pressed(state, "g")) == 0
  end

  test "rows are put in order and picked out" do
    snapshot = Watched.snapshot()
    state = State.new(nil, 10)
    names = fn state -> state |> State.groups(snapshot) |> Enum.map(& &1.name) end

    # By work, the busiest first, and what has no figure yet last.
    assert names.(state) == ["MyApp.Repo", "MyApp.Worker", "New.Thing"]
    state = pressed(state, "s")
    assert state.sort == :memory
    assert hd(names.(state)) == "MyApp.Repo"
    state = pressed(state, "s")
    assert state.sort == :queue
    assert hd(names.(state)) == "MyApp.Worker"
    state = pressed(state, "s")
    assert state.sort == :name
    assert names.(state) == ["MyApp.Repo", "MyApp.Worker", "New.Thing"]
    assert pressed(state, "s").sort == :work

    state = pressed(state, "/WORK")
    assert state.typing
    assert names.(state) == ["MyApp.Worker"]
    # While typing, a key is a letter and not a command.
    state = pressed(state, "q")
    refute state.quit
    assert state.filter == "WORKq"
    {state, :view} = key(state, :backspace)
    # What is wanted has been said: there is reading to do.
    assert {state, :moment} = key(state, :enter)
    refute state.typing
    assert names.(state) == ["MyApp.Worker"]

    # A process is picked out by its name, its application, or its pid.
    state = pressed(state, "2")
    assert [%{name: "worker_7"}] = State.processes(state, snapshot)
    {state, _} = key(pressed(state, "/0.512"), :enter)
    assert [%{name: "MyApp.Repo"}] = State.processes(state, snapshot)
    {state, _} = key(pressed(state, "/my_app"), :enter)
    assert length(State.processes(state, snapshot)) == 2

    {state, :moment} = key(pressed(state, "/"), :esc)
    assert state.filter == ""
    assert length(State.processes(state, snapshot)) == 2
    refute State.looking?(state)
  end

  test "the first view is of applications when they are asked for" do
    snapshot = Watched.snapshot()
    state = State.new(nil, 10)
    assert length(State.groups(state, snapshot)) == 3

    state = pressed(pressed(state, "j"), "a")
    assert state.apps
    assert State.selected(state) == 0
    assert Enum.map(State.groups(state, snapshot), & &1.name) == ["my_app", "none"]
    refute pressed(state, "a").apps
  end

  test "a group is gone into and come out of" do
    snapshot = Watched.snapshot()
    state = State.new(nil, 10)
    # The row is opened by whoever knows what is in it.
    assert {_state, :open} = key(state, :enter)

    state = State.enter(%{state | filter: "worker"}, {:group, "MyApp.Worker"})
    assert state.tab == :processes
    assert state.filter == ""
    assert [%{name: "worker_7"}] = State.processes(state, snapshot)
    assert [] = State.processes(State.enter(state, {:app, "none"}), snapshot)
    assert length(State.processes(State.enter(state, {:app, "my_app"}), snapshot)) == 2

    # Escape leaves the group, and not the program.
    assert {state, :moment} = key(state, :esc)
    refute state.quit
    assert state.tab == :groups
    assert state.within == nil
    state = pressed(state, "2")
    assert length(State.processes(state, snapshot)) == 2
    {state, _} = key(state, :esc)
    assert state.quit

    {state, _} = key(State.enter(State.new(nil, 10), {:group, "MyApp.Worker"}), :backspace)
    assert state.within == nil
    # With no group to leave, it is not a key.
    assert {_state, :nothing} = key(state, :backspace)
  end

  test "a moment is gone to by typing it" do
    {state, :view} = press(State.new(nil, 10), "t")
    assert state.going == ""
    # While typing, a key is a letter and not a command.
    state = pressed(state, "-10mq")
    {state, :view} = key(state, :backspace)
    assert state.going == "-10m"
    assert {state, :moment} = key(state, :enter)
    assert state.going == nil
    assert state.at == 4430.0

    # What is after the last moment stored is now.
    {state, _} = key(pressed(state, "t-5s"), :enter)
    assert State.live?(state)

    # What is before the first is the first, and says so.
    {state, :moment} = key(pressed(state, "t-2h"), :enter)
    assert state.at == 1000.0
    assert state.message =~ "The store begins at"
    # The next key puts what was said away.
    assert pressed(state, "j").message == nil

    # What is not a time is refused, and nothing moves.
    assert {state, :view} = key(pressed(state, "tyesterday"), :enter)
    assert state.at == 1000.0
    assert state.message =~ "yesterday"

    {state, :view} = key(pressed(state, "t12"), :esc)
    assert state.going == nil
    assert state.at == 1000.0

    # Nothing typed is nowhere to go.
    assert {%{going: nil, at: 1000.0}, :view} = key(pressed(state, "t"), :enter)

    # With nothing stored, there is nowhere to go.
    {state, :view} = key(pressed(State.new(nil, 10), "t-5m"), :enter, nil)
    assert state.message == "There is nothing stored to go to."
  end

  test "the timeline is drawn out to have a recording" do
    state = State.new(nil, 10)
    assert State.fit(state, nil) == state
    assert State.window(State.fit(state, 90)) == 600.0
    assert State.window(State.fit(state, 3600)) == 3600.0
    assert State.window(State.fit(state, 3601)) == 6 * 3600.0
    assert State.window(State.fit(state, 8 * 3600)) == 86_400.0
    # As far as it can be.
    assert State.window(State.fit(state, 30 * 86_400)) == 7 * 86_400.0
  end

  test "the timeline is drawn out and drawn in" do
    state = State.new(nil, 10)
    assert State.window(state) == 3600.0
    assert {state, :moment} = press(state, "-")
    assert State.window(state) == 6 * 3600.0
    state = pressed(state, "---")
    assert State.window(state) == 7 * 86_400.0
    assert {_state, :nothing} = press(state, "-")
    state = pressed(state, "++++")
    assert State.window(state) == 600.0
    assert {_state, :nothing} = press(state, "=")
  end

  test "the moment of a row is gone to" do
    state = pressed(State.new(nil, 10), "4jjj")
    assert {state, :go} = press(state, "m")
    # By whoever knows when the row was.
    state = State.go_to(state, 3217.4, @range)
    assert state.at == 3210.0
    assert State.selected(state) == 0
    assert State.live?(State.go_to(state, 9999.0, @range))
    assert State.go_to(state, 5.0, @range).at == 1000.0
    assert State.go_to(state, 2000.0, nil).at == 3210.0
  end

  test "leaving" do
    state = pressed(State.new(nil, 10), "?")
    assert state.help
    # Any key puts the help away, and does nothing else.
    state = pressed(state, "q")
    refute state.help or state.quit
    assert pressed(state, "h").help
    assert pressed(state, "q").quit

    # What is known of a row is put away in the same way.
    {state, :view} = key(%{State.new(nil, 10) | inspecting: true}, :enter)
    refute state.inspecting

    # Whatever is being typed.
    {state, _} = key(%{State.new(nil, 10) | typing: true}, :ctrl_c)
    assert state.quit
  end

  test "what is wanted is wanted by any of what is said of it" do
    state = %{State.new(nil, 10) | filter: "KILL"}
    assert State.wants?(state, ["MyApp.Worker", "killed"])
    refute State.wants?(state, ["MyApp.Worker", "normal", nil])
    assert State.wants?(State.new(nil, 10), [])
  end
end
