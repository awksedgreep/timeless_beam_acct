defmodule TimelessBeamAcct.EndingTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.Ending

  defmodule Broken do
    defexception [:field]
    def message(_), do: raise("no message")
  end

  test "ending, and being told to shut down, are how a process is meant to end" do
    assert %Ending{status: "normal", class: :normal, reason: nil} = Ending.of(:normal)
    assert %Ending{status: "shutdown", class: :normal, reason: nil} = Ending.of(:shutdown)

    assert %Ending{status: "shutdown", class: :normal, reason: reason} =
             Ending.of({:shutdown, :closed})

    assert reason == "{:shutdown, :closed}"
    assert Ending.ok?(Ending.of(:normal))
  end

  test "a reason of the process's own is not a crash" do
    assert %Ending{status: "custom", class: :abnormal, reason: ":custom"} = Ending.of(:custom)

    ending = Ending.of({:timeout, {GenServer, :call, [:server, :request, 5000]}})
    assert ending.status == "timeout"
    assert ending.class == :abnormal
    assert ending.reason == "{:timeout, {GenServer, :call, [:server, :request, 5000]}}"
    assert Ending.ok?(ending) == false
    assert Ending.words(ending) == "exited timeout"
  end

  test "being killed is its own ending" do
    assert %Ending{status: "killed", class: :killed} = ending = Ending.of(:killed)
    assert Ending.words(ending) == "killed"
  end

  test "what was raised is a crash, and says where" do
    {reason, stack} =
      try do
        raise "boom"
      rescue
        error -> {error, __STACKTRACE__}
      end

    ending = Ending.of({reason, stack})
    assert ending.status == "RuntimeError"
    assert ending.class == :crashed
    assert ending.reason == "RuntimeError: boom"
    assert ending.at =~ "ending_test.exs"
    assert Ending.words(ending) == "crashed: RuntimeError"
  end

  test "an error of the VM's own is named for what it is" do
    stack = [
      {:erlang, :hd, [[]], [error_info: %{module: :erl_erts_errors}]},
      {My, :fun, 2, [file: ~c"my.ex", line: 3]}
    ]

    assert %Ending{status: "badarg", class: :crashed, at: at} = Ending.of({:badarg, stack})
    assert at == ":erlang.hd/1"

    assert %Ending{status: "badmatch", class: :crashed} = Ending.of({{:badmatch, 5}, stack})
    assert %Ending{status: "nocatch", class: :crashed} = Ending.of({{:nocatch, :thrown}, stack})
  end

  test "a pair whose second is a list of anything else is not a crash" do
    assert %Ending{status: "stopped", class: :abnormal} = Ending.of({:stopped, [1, 2]})
    assert %Ending{status: "stopped", class: :abnormal} = Ending.of({:stopped, []})
  end

  test "a reason that holds what the process held is cut short" do
    ending = Ending.of({:bad_state, String.duplicate("x", 10_000), Enum.to_list(1..10_000)})
    assert ending.status == "bad_state"
    assert String.length(ending.reason) <= 200
    assert ending.reason =~ "..."

    ending = Ending.of({:bad_state, String.duplicate("x", 500), String.duplicate("y", 500)})
    assert String.length(ending.reason) == 200
    assert String.ends_with?(ending.reason, "…")
  end

  test "a reason that begins with nothing nameable is other" do
    assert Ending.of({1, 2}).status == "other"
    assert Ending.of("a string").status == "other"
    assert Ending.of({{}, 1}).status == "other"
  end

  test "an exception whose message cannot be had is written as it is" do
    stack = [{My, :fun, 2, [file: ~c"my.ex", line: 3]}]
    ending = Ending.of({%Broken{field: 1}, stack})
    assert ending.class == :crashed
    assert ending.status == "TimelessBeamAcct.EndingTest.Broken"
    assert ending.reason =~ "Broken"
  end

  test "a call from another node ended as the call did" do
    asked = make_ref()
    stack = [{My, :fun, 2, [file: ~c"my.ex", line: 3]}]

    assert %Ending{status: "normal", class: :normal, reason: nil} =
             Ending.of({asked, :return, {:ok, :an_answer}})

    assert %Ending{status: "timeout", class: :abnormal} =
             Ending.of({asked, :exit, {:timeout, :call}})

    assert %Ending{status: "normal", class: :normal} = Ending.of({asked, :exit, :normal})

    assert %Ending{status: "badarg", class: :crashed, at: at} =
             Ending.of({asked, :error, :badarg, stack})

    assert at =~ "My.fun/2"

    assert %Ending{status: "nocatch", class: :abnormal, reason: "{:nocatch, :thrown}"} =
             Ending.of({asked, :throw, :thrown})
  end

  test "a process noticed gone ended in a way that is not known" do
    ending = Ending.unknown()
    assert ending.status == "unknown"
    assert Ending.ok?(ending) == nil
    assert Ending.words(ending) == "gone"
  end
end
