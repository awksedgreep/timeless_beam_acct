defmodule TimelessBeamAcct.Watch.ViewTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.Clock
  alias TimelessBeamAcct.Watch.{Canvas, Data, State, View}
  alias TimelessBeamAcct.Watch.View.Detail
  alias TimelessBeamAcct.Watched

  @at 1_753_000_000.0

  # The screen, as the text on it.
  defp screen(state, snapshot, detail, size \\ {110, 30}) do
    {_state, canvas} = View.draw(state, snapshot, detail, size)
    canvas |> Canvas.text() |> Enum.join("\n")
  end

  defp detail do
    %Detail{
      now: @at + 300,
      node: "app@ohm",
      range: {@at - 1_000_000, @at + 290},
      history: [{@at + 280, 12.0}, {@at + 290, 40.0}],
      history_of: "MyApp.Repo work",
      history_span: 600.0,
      history_until: @at + 290,
      step: 10.0,
      timeline_step: 10.0
    }
  end

  defp ended(fields) do
    Map.merge(
      %{
        at: @at + 200,
        name: "MyApp.Worker",
        pid: "<0.4242.0>",
        app: "my_app",
        status: "RuntimeError",
        level: "error",
        elapsed: 0.394,
        whole: true,
        reductions: 48_100,
        peak_memory: 2_400_000,
        process: "MyApp.Worker (worker_7)",
        fields: %{}
      },
      Map.new(fields)
    )
  end

  defp job(fields) do
    Map.merge(
      %{
        started: @at + 100,
        duration: 2.5,
        reductions: 12_000,
        processes: 3,
        failed: 1,
        app: "my_app",
        name: "MyApp.Batch",
        running: false,
        tree: [
          "MyApp.Batch  2.5s, 2.1k reductions",
          "└─ MyApp.Worker  1.0s, 9.9k reductions  [crashed: RuntimeError]"
        ]
      },
      Map.new(fields)
    )
  end

  test "the node is on the screen with its busiest group first" do
    text = screen(State.new(nil, 10), Watched.snapshot(@at), detail())

    assert text =~ "timeless-beam-acct app@ohm"
    assert text =~ "● LIVE " <> Clock.format(@at)
    assert text =~ "run queue 2   schedulers 12.5% (cpu 145.5%)"
    assert text =~ "mem 131 MiB (processes 60.0 MiB binary 12.0 MiB ets 8.0 MiB)"
    assert text =~ "work 48.1k reds/s   processes 512 (+25.0 -24.5/s)   gc 120/s"
    assert text =~ "io ↓1.5 KiB/s ↑0 B/s   atoms 4.1%   up 2h03m"

    lines = String.split(text, "\n")
    first = Enum.find_index(lines, &String.starts_with?(&1, "GROUP")) + 1
    assert Enum.at(lines, first) =~ ~r/^MyApp.Repo\s+40.0\s+1.9 GiB\s+1\s+0\s+19.0k\s+0.0$/

    assert Enum.at(lines, first + 1) =~
             ~r/^MyApp.Worker\s+12.0\s+2.9 MiB\s+50\s+1.2k\s+5.7k\s+2.5$/

    # A group with no figures yet has none, and is last.
    assert Enum.at(lines, first + 2) =~ ~r/^New.Thing\s+-\s+0 B\s+0\s+-\s+-\s+-$/

    assert text =~ "MyApp.Repo work, the 10m00s before"
    assert text =~ "peak 40.0%"
    assert text =~ " 1 Groups  2 Processes  3 Jobs  4 Exits    by work"
    assert List.last(lines) =~ " ←→ 10s ,. 1m <> 10m [] 1h t go to l live -+ zoom tab view"
  end

  test "a line of the node has what there is room for, and nothing is cut" do
    text = screen(State.new(nil, 10), Watched.snapshot(@at), detail(), {60, 20})
    [_, first, second | _] = String.split(text, "\n")
    assert String.length(first) == 60

    assert first |> String.trim("│") |> String.trim() ==
             "run queue 2   schedulers 12.5% (cpu 145.5%)   mem 131 MiB"

    assert second |> String.trim("│") |> String.trim() ==
             "work 48.1k reds/s   processes 512 (+25.0 -24.5/s)"
  end

  test "a moment gone back to says when it was" do
    text = screen(State.new(@at, 10), Watched.snapshot(@at), detail())
    refute text =~ "LIVE"
    assert text =~ "◀ " <> Clock.format(@at)
    assert text =~ "5m00s ago"
  end

  test "a moment with nothing in it says why" do
    empty = %Data{}

    assert screen(State.new(@at - 2_000_000, 10), empty, detail()) =~ "Before the store began."

    assert screen(State.new(@at - 500_000, 10), empty, detail()) =~
             "the collector was not running"

    nothing = %{detail() | range: nil}
    assert screen(State.new(nil, 10), empty, nothing) =~ "The store holds nothing yet."

    assert screen(State.new(nil, 10), empty, %{nothing | stored: false}) =~
             "The collector has read nothing yet."
  end

  test "processes, jobs, and exits each have a view" do
    snapshot = Watched.snapshot(@at)
    detail = %{detail() | jobs: [job([])], exits: [ended([])]}

    text = screen(%{State.new(nil, 10) | tab: :processes}, snapshot, detail)
    assert text =~ ~r/PROCESS\s+PID\s+APP\s+WORK%\s+MEMORY\s+MSGQ\s+REDS/
    repo = text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "MyApp.Repo"))
    assert repo =~ ~r/<0.512.0> my_app\s+38.0\s+1.8 GiB\s+0\s+9.0M$/

    text = screen(%{State.new(nil, 10) | tab: :jobs}, snapshot, detail)
    assert text =~ ~r/STARTED\s+PROCS FAILED TOOK\s+REDS\s+JOB\s+APP/

    assert text =~
             ~r/#{Clock.format(@at + 100) |> String.slice(11..-1//1)}\s+3\s+1\s+2.5s\s+12.0k MyApp.Batch\s+my_app/

    assert text =~ "┌ what it was "
    assert text =~ "└─ MyApp.Worker  1.0s, 9.9k reductions  [crashed: RuntimeError]"

    state = %{State.new(nil, 10) | tab: :exits}
    text = screen(state, snapshot, detail)
    line = text |> String.split("\n") |> Enum.find(&(&1 =~ "RuntimeError"))

    assert line =~
             ~r/<0.4242.0> RuntimeError\s+394ms\s+48.1k\s+2.3 MiB MyApp.Worker \(worker_7\)$/

    # An exit is picked out by how it ended, as well as by what it was.
    assert screen(%{state | filter: "runtime"}, snapshot, detail) =~ "MyApp.Worker (worker_7)"
    # What does not match is not shown.
    refute screen(%{state | filter: "nothing-like-it"}, snapshot, detail) =~ "RuntimeError"
  end

  test "an exit with no figures, or of a process older than the collector, says so" do
    detail = %{
      detail()
      | exits: [
          ended(reductions: nil, peak_memory: nil, status: "normal", level: "info"),
          ended(elapsed: 90.0, whole: false, status: "killed", level: "warning", pid: "<0.9.0>")
        ]
    }

    text = screen(%{State.new(nil, 10) | tab: :exits}, Watched.snapshot(@at), detail)
    assert text =~ ~r/<0.4242.0> normal\s+394ms\s+-\s+- MyApp.Worker/
    assert text =~ ~r/<0.9.0> killed\s+>1m30s /
  end

  test "a job that is running says so, and no jobs is said" do
    state = %{State.new(nil, 10) | tab: :jobs}
    detail = %{detail() | jobs: [job(running: true, duration: 95.0, failed: 0)]}
    assert screen(state, Watched.snapshot(@at), detail) =~ ~r/3\s+-\s+1m35s…/

    assert screen(state, Watched.snapshot(@at), detail()) =~
             "No jobs in the quarter of an hour before. A job is more than one process."
  end

  test "what is known of a process is shown over the rest" do
    lines = [
      {"was", "MyApp.Worker"},
      {"reason", "RuntimeError: " <> String.duplicate("it went wrong again ", 12)},
      {"ended", "exited normal, after 2.5s"}
    ]

    detail = %{detail() | inspected: {"MyApp.Worker<0.4242.0>", lines}}
    text = screen(%{State.new(nil, 10) | inspecting: true}, Watched.snapshot(@at), detail)

    assert text =~ " MyApp.Worker<0.4242.0> "
    assert text =~ " any key "
    assert text =~ "was            MyApp.Worker"
    # Folded, and not cut: all of the reason is there.
    assert length(String.split(text, "wrong")) == 13
    assert length(String.split(text, "again")) == 13
    assert text =~ "ended          exited normal, after 2.5s"

    # Unless it is asked for, it is not shown.
    refute screen(State.new(nil, 10), Watched.snapshot(@at), detail) =~ "any key"
  end

  test "the keys are said over the rest when they are asked for" do
    text = screen(%{State.new(nil, 10) | help: true}, Watched.snapshot(@at), detail(), {110, 40})
    assert text =~ "┌ keys "
    assert text =~ "tab, 1-4   groups, processes, jobs, exits"
    assert text =~ "a          applications, in place of groups"
    assert text =~ "Now is what the collector in the node last read."
  end

  test "what went wrong is marked under the moment it happened" do
    incidents = [
      %{at: 105.0, error: false},
      %{at: 131.0, error: true},
      # A kill and a fault in the same column: the fault shows.
      %{at: 138.0, error: false},
      %{at: 171.0, error: false},
      # Outside the stretch.
      %{at: 50.0, error: true},
      %{at: 250.0, error: true}
    ]

    assert View.marks(10, 100.0, 200.0, 155.0, incidents) ==
             [:killed, :nothing, :nothing, :fault, :nothing, :here] ++
               [:nothing, :killed, :nothing, :nothing]

    at = &View.marks(10, 100.0, 200.0, &1, incidents)
    # Looking at the moment something went wrong.
    assert Enum.at(at.(131.0), 3) == :here_fault
    assert Enum.at(at.(171.0), 7) == :here_killed
    # Now is at the right end.
    assert Enum.at(at.(200.0), 9) == :here
    # A moment outside the stretch is not on it.
    refute :here in at.(999.0)
    assert View.marks(0, 100.0, 200.0, 150.0, incidents) == []
  end

  test "the timeline is in the header with the stretch it shows" do
    window = {@at - 1800, @at + 1800}

    detail = %{
      detail()
      | window: window,
        timeline: for(n <- 0..359, do: {@at - 1800 + 10 * n, rem(n, 50) / 1}),
        incidents: [%{at: @at - 900, error: true}]
    }

    text = screen(State.new(@at, 10), Watched.snapshot(@at), detail)
    lines = String.split(text, "\n")

    # The moment looked at is in the middle of the stretch, and what went
    # wrong a quarter of the way along it.
    marked = lines |> Enum.at(4) |> String.graphemes()
    assert Enum.find_index(marked, &(&1 == "▲")) in 54..56
    assert Enum.find_index(marked, &(&1 == "!")) in 27..29
    assert Enum.at(lines, 3) =~ "▁" or Enum.at(lines, 3) =~ "▂"
    assert Enum.at(lines, 5) =~ " schedulers over 1h00m, up to 49.0% "
    assert Enum.at(lines, 5) =~ String.slice(Clock.format(@at - 1800), 11, 5)

    # A stretch of a day or more is told by the day as well: a day's two
    # ends are the same time.
    for span <- [86_400, 7 * 86_400] do
      long = %{detail | window: {@at - span, @at}}
      text = screen(State.new(@at, 10), Watched.snapshot(@at), long)
      assert text =~ " " <> String.slice(Clock.format(@at), 5, 11) <> " "
      assert text =~ " " <> String.slice(Clock.format(@at - span), 5, 11) <> " "
    end
  end

  test "a text is folded between its words" do
    assert View.fold("a b c", 40) == ["a b c"]
    assert View.fold("cc -c a.c -o a.o", 9) == ["cc -c a.c", "-o a.o"]
    assert View.fold("one two three", 7) == ["one two", "three"]
    # A word longer than a line is broken where the line ends.
    assert View.fold("ld /usr/lib/very/long/path.o -o x", 10) ==
             ["ld", "/usr/lib/v", "ery/long/p", "ath.o -o x"]

    assert View.fold("", 10) == [""]
    assert View.fold("héllo wörld", 5) == ["héllo", "wörld"]
  end

  test "a group gone into, a moment being typed, and what is said, are said" do
    state = State.enter(State.new(nil, 10), {:group, "MyApp.Worker"})
    text = screen(state, Watched.snapshot(@at), detail())
    assert text =~ "in MyApp.Worker"
    assert text =~ "esc back to groups"
    refute text =~ "MyApp.Repo<"
    assert text =~ "worker_7"

    text = screen(%{state | going: "-15"}, Watched.snapshot(@at), detail())
    assert text =~ "go to -15▏"
    assert text =~ "enter to go, esc to stay"

    text = screen(%{state | message: "\"soon\" is not a time"}, Watched.snapshot(@at), detail())
    assert text =~ "\"soon\" is not a time"

    text =
      screen(%{State.new(nil, 10) | typing: true, filter: "rep"}, Watched.snapshot(@at), detail())

    assert text =~ "only rep▏"
    assert text =~ " enter keep esc clear"

    text = screen(%{State.new(nil, 10) | apps: true}, Watched.snapshot(@at), detail())
    assert text =~ "by work   applications"
    assert text =~ ~r/^APP\s+WORK%/m
    assert text =~ ~r/^my_app\s+52.0/m
  end

  test "trouble reading is said, and the screen is still drawn" do
    detail = %{detail() | error: "http://127.0.0.1:1: connection refused"}
    text = screen(State.new(nil, 10), Watched.snapshot(@at), detail)
    assert text =~ "http://127.0.0.1:1: connection refused"
    assert text =~ "MyApp.Repo"
  end

  test "a history is laid out in time with the latest at the right" do
    # A sample every ten seconds, drawn a column to five.
    history = [{100.0, 1.0}, {110.0, 2.5}, {190.0, 3.0}, {200.0, 4.0}]

    # None came: the collector was not running.
    assert View.columns(history, 200.0, 100.0, 20, 10.0) ==
             [1.0, 1.0, 2.5, 2.5, 2.5] ++
               List.duplicate(0.0, 13) ++ [3.0, 4.0]
  end

  test "a history longer than the screen is wide shows its peaks" do
    history = for n <- 0..99, do: {100.0 + n, if(n == 37, do: 9.0, else: 1.0)}

    assert View.columns(history, 200.0, 100.0, 10, 1.0) ==
             [1.0, 1.0, 1.0, 9.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
  end

  test "what is outside the stretch is not drawn" do
    # Before it, and standing no longer.
    assert View.columns([{50.0, 9.0}], 200.0, 100.0, 2, 10.0) == [0.0, 0.0]
    # Just before it, and standing still.
    assert View.columns([{95.0, 9.0}], 200.0, 100.0, 4, 10.0) == [9.0, 0.0, 0.0, 0.0]
    assert View.columns([{150.0, 1.0}], 200.0, 100.0, 0, 10.0) == []
    assert View.columns([], 200.0, 100.0, 3, 10.0) == [0.0, 0.0, 0.0]
  end

  test "a history says what it is of, and why there is none" do
    snapshot = Watched.snapshot(@at)
    none = %{detail() | history: []}

    assert screen(State.new(nil, 10), snapshot, none) =~
             "Not in the store: it has no series of its own, or none yet."

    assert screen(State.new(nil, 10), snapshot, %{none | stored: false}) =~
             "The collector writes to nothing that can be asked."

    assert screen(State.new(nil, 10), snapshot, %{none | history_of: ""}) =~ " nothing selected "

    memory = %{detail() | history_kind: :memory, history: [{@at, 3.0e6}]}
    assert screen(State.new(nil, 10), snapshot, memory) =~ "peak 2.9 MiB"
    queue = %{detail() | history_kind: :queue, history: [{@at, 1200.0}]}
    assert screen(State.new(nil, 10), snapshot, queue) =~ "peak 1.2k waiting"
  end

  test "the picked row names the history to read" do
    snapshot = Watched.snapshot(@at)
    state = State.new(nil, 10)

    assert View.history_of(state, snapshot) ==
             {"beam_group_work_pct", "group", "MyApp.Repo", "MyApp.Repo work", :work}

    assert {"beam_app_work_pct", "app", "my_app", _, :work} =
             View.history_of(%{state | apps: true}, snapshot)

    state = %{state | sort: :memory, tab: :processes}

    assert View.history_of(state, snapshot) ==
             {"beam_proc_memory_bytes", "proc", "MyApp.Repo<0.512.0>",
              "MyApp.Repo<0.512.0> memory", :memory}

    assert {"beam_proc_message_queue_len", "proc", "worker_7<0.700.0>", _, :queue} =
             View.history_of(%{state | sort: :queue}, snapshot)

    assert View.history_of(%{state | tab: :jobs}, snapshot) == nil
    assert View.history_of(%{state | filter: "no such"}, snapshot) == nil
  end

  test "a screen too small for all of it is still drawn" do
    for size <- [{40, 12}, {40, 8}, {20, 4}] do
      for tab <- State.tabs() do
        state = %{State.new(nil, 10) | tab: tab, help: true, inspecting: true}
        detail = %{detail() | jobs: [job([])], exits: [ended([])], inspected: {"x", [{"a", "b"}]}}
        assert is_binary(screen(state, Watched.snapshot(@at), detail, size))
      end
    end
  end
end
