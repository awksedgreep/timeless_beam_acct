defmodule TimelessBeamAcct.ReportTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.{Clock, Event, Report, Span}

  doctest TimelessBeamAcct.Report

  @now 1_790_000_000.0

  # Six characters, eight code points, ten bytes.
  @combining "re\u0301sume\u0301"

  # A record of a process that ended `ago` seconds before now.
  defp ended(ago, fields) do
    %Event{
      ts_us: trunc((@now - ago) * 1_000_000),
      level: :info,
      message: "a process ended",
      fields:
        Map.merge(
          %{"kind" => "exit", "source" => "traced", "app" => "my_app", "status" => "normal"},
          fields
        )
    }
  end

  defp at(ago), do: Clock.format(@now - ago)

  defp pids(events), do: Enum.map(events, & &1.fields["pid"])

  # Four that ended, and one remark, in no order.
  defp records do
    [
      ended(30, %{
        "service" => "MyApp.Worker",
        "name" => "MyApp.Worker.One",
        "status" => "killed",
        "pid" => "<0.512.0>",
        "reason" => "killed",
        "started" => @now - 30.394,
        "elapsed_seconds" => 0.394,
        "reductions" => 48_100,
        "memory_bytes" => 2_000_000,
        "peak_memory_bytes" => 2_411_724,
        "message_queue_len" => 0
      }),
      ended(3000, %{
        "service" => "fn in MyApp.Foo.bar/2",
        "pid" => "<0.77.0>",
        "started" => @now - 3000.001,
        "elapsed_seconds" => 0.001
      }),
      %{
        ended(5, %{
          "kind" => "long_gc",
          "service" => "MyApp.Worker",
          "pid" => "<0.600.0>",
          "value" => 120,
          "unit" => "ms"
        })
        | level: :warning
      }
      |> Map.update!(:fields, &Map.drop(&1, ["status", "source"])),
      ended(20, %{
        "source" => "sampled",
        "service" => "code_server",
        "name" => "code_server",
        "status" => "unknown",
        "pid" => "<0.50.0>",
        "app" => "kernel",
        "seen_seconds" => 40.0,
        "reductions" => 1_200_000,
        "peak_memory_bytes" => 700 * 1024 * 1024
      }),
      ended(10, %{
        "service" => "MyApp.Worker",
        "status" => "RuntimeError",
        "pid" => "<0.12345.0>",
        "crashed" => true,
        "reason" => "%RuntimeError{message: \"no\"}",
        "started" => @now - 125.0,
        "elapsed_seconds" => 115.0,
        "reductions" => 5_500_000,
        "peak_memory_bytes" => 1024
      })
    ]
  end

  describe "figures" do
    test "a length of time is written as the Rust writes it" do
      assert Report.human_duration(0.34) == "340ms"
      assert Report.human_duration(12.54) == "12.5s"
      assert Report.human_duration(247.0) == "4m07s"
      assert Report.human_duration(7380.0) == "2h03m"
      assert Report.human_duration(90_000.0) == "1d01h"
    end

    test "a length of time may be an integer, and one below zero is none" do
      assert Report.human_duration(0) == "0ms"
      assert Report.human_duration(115) == "1m55s"
      assert Report.human_duration(-3) == "0ms"
      assert Report.human_duration(-0.5) == "0ms"
    end

    test "a length of time is rounded within its unit, not into the next" do
      assert Report.human_duration(0.9996) == "1000ms"
      assert Report.human_duration(59.96) == "60.0s"
      assert Report.human_duration(3599.9) == "59m59s"
      assert Report.human_duration(86_399.0) == "23h59m"
    end

    test "a length of time under a millisecond is in microseconds" do
      assert Report.human_duration(0) == "0ms"
      assert Report.human_duration(0.000_000_4) == "0µs"
      assert Report.human_duration(0.000_007) == "7µs"
      assert Report.human_duration(0.000_25) == "250µs"
      assert Report.human_duration(0.000_999) == "999µs"
      # What would be written as a thousand of them is a millisecond.
      assert Report.human_duration(0.000_999_6) == "1ms"
      assert Report.human_duration(0.001) == "1ms"
    end

    test "a tie is rounded to the even digit, as the Rust rounds it" do
      assert Report.human_duration(0.0025) == "2ms"
      assert Report.human_duration(0.0015) == "2ms"
      assert Report.human_duration(2.25) == "2.2s"
      assert Report.human_duration(2.75) == "2.8s"
      assert Report.human_bytes(1024 + 256) == "1.2 KiB"
      assert Report.human_bytes(1024 + 768) == "1.8 KiB"
      assert Report.human_count(12_500.0) == "12.5k"
      assert Report.human_count(250.25) == "250.2"
    end

    test "a size is written as the Rust writes it" do
      assert Report.human_bytes(512) == "512 B"
      assert Report.human_bytes(12 * 1024) == "12.0 KiB"
      assert Report.human_bytes(340 * 1024 * 1024) == "340 MiB"
      assert Report.human_bytes(1536 * 1024 * 1024) == "1.5 GiB"
    end

    test "a size has no unit beyond the last" do
      assert Report.human_bytes(0) == "0 B"
      assert Report.human_bytes(1023) == "1023 B"
      assert Report.human_bytes(1024) == "1.0 KiB"
      assert Report.human_bytes(1024 * 1024 - 1) == "1024 KiB"
      assert Report.human_bytes(5 * 1024 ** 5) == "5120 TiB"
      assert Report.human_bytes(2048.9) == "2.0 KiB"
      assert Report.human_bytes(-1) == "0 B"
    end

    test "a count is written in thousands" do
      assert Report.human_count(999) == "999"
      assert Report.human_count(12_400) == "12.4k"
      assert Report.human_count(1_200_000) == "1.2M"
      assert Report.human_count(3_400_000_000) == "3.4G"
      assert Report.human_count(7_000_000_000_000) == "7.0T"
      assert Report.human_count(5.0e15) == "5000T"
    end

    test "a count below a thousand is as it is, and a float to one decimal unless it is whole" do
      assert Report.human_count(0) == "0"
      assert Report.human_count(12.0) == "12"
      assert Report.human_count(12.34) == "12.3"
      assert Report.human_count(0.04) == "0.0"
      assert Report.human_count(1000) == "1.0k"
      assert Report.human_count(48_100.0) == "48.1k"
      assert Report.human_count(-12_400) == "-12.4k"
    end

    test "a count of a hundred of a unit or more has no decimal place" do
      assert Report.human_count(99_900) == "99.9k"
      assert Report.human_count(99_960) == "100k"
      assert Report.human_count(182_000) == "182k"
    end

    test "a count that rounds to a thousand is one of the next unit" do
      assert Report.human_count(999.96) == "1.0k"
      assert Report.human_count(999_400) == "999k"
      assert Report.human_count(999_950) == "1.0M"
    end
  end

  describe "filter_events/2" do
    test "with nothing asked for, the processes that ended are given oldest first" do
      assert records() |> Report.filter_events() |> pids() ==
               ["<0.77.0>", "<0.512.0>", "<0.50.0>", "<0.12345.0>"]
    end

    test "since and until are by when the process ended, and include their ends" do
      assert records() |> Report.filter_events(since: "-30s", now: @now) |> pids() ==
               ["<0.512.0>", "<0.50.0>", "<0.12345.0>"]

      assert records() |> Report.filter_events(until: "-20s", now: @now) |> pids() ==
               ["<0.77.0>", "<0.512.0>", "<0.50.0>"]

      assert records()
             |> Report.filter_events(since: @now - 25, until: @now - 15, now: @now)
             |> pids() == ["<0.50.0>"]

      assert Report.filter_events(records(), since: "-1s", now: @now) == []
    end

    test "a time may be written in any of the ways a time is written" do
      moment = DateTime.from_unix!(trunc(@now) - 25)

      for since <- [moment, @now - 25, "#{trunc(@now) - 25}", at(25), "-25s"] do
        assert records() |> Report.filter_events(since: since, now: @now) |> pids() ==
                 ["<0.50.0>", "<0.12345.0>"]
      end
    end

    test "a time that is not a time is refused, in the clock's words" do
      {:error, why} = Clock.parse("yesterday", @now)

      assert_raise ArgumentError, why, fn ->
        Report.filter_events(records(), since: "yesterday", now: @now)
      end

      assert_raise ArgumentError, ~r/is not a time/, fn ->
        Report.filter_events(records(), until: "25:00", now: @now)
      end

      assert_raise ArgumentError, ":yesterday is not a time", fn ->
        Report.filter_events(records(), since: :yesterday, now: @now)
      end
    end

    test "an until before its since is refused" do
      assert_raise ArgumentError, ":until is before :since", fn ->
        Report.filter_events(records(), since: "-1m", until: "-2m", now: @now)
      end
    end

    test "a status is matched exactly" do
      assert records() |> Report.filter_events(status: "killed") |> pids() == ["<0.512.0>"]
      assert Report.filter_events(records(), status: "kill") == []
    end

    test "a group is matched exactly, and may be written as the module it is" do
      assert records() |> Report.filter_events(group: "MyApp.Worker") |> pids() ==
               ["<0.512.0>", "<0.12345.0>"]

      assert records() |> Report.filter_events(group: MyApp.Worker) |> pids() ==
               ["<0.512.0>", "<0.12345.0>"]

      assert records() |> Report.filter_events(group: :code_server) |> pids() == ["<0.50.0>"]

      # The name a process was registered under is not what it was.
      assert Report.filter_events(records(), group: "MyApp.Worker.One") == []
    end

    test "an application is matched exactly" do
      assert records() |> Report.filter_events(app: "kernel") |> pids() == ["<0.50.0>"]
      assert Report.filter_events(records(), app: "my") == []
    end

    test "a process failed if it ended as anything but normal or shutdown, and is known to have" do
      shutdown =
        ended(1, %{"service" => "MyApp.Worker", "status" => "shutdown", "pid" => "<0.9.0>"})

      # How the one that was noticed gone ended is not known.
      assert [shutdown | records()] |> Report.filter_events(failed: true) |> pids() ==
               ["<0.512.0>", "<0.12345.0>"]

      assert [shutdown | records()] |> Report.filter_events(failed: false) |> pids() ==
               ["<0.77.0>", "<0.512.0>", "<0.50.0>", "<0.12345.0>", "<0.9.0>"]
    end

    test "a kind is exit unless another is asked for, and any is all of them" do
      assert records() |> Report.filter_events(kind: "long_gc") |> pids() == ["<0.600.0>"]
      assert records() |> Report.filter_events(kind: :long_gc) |> pids() == ["<0.600.0>"]
      assert Report.filter_events(records(), kind: "busy_port") == []

      assert records() |> Report.filter_events(kind: :any) |> pids() ==
               ["<0.77.0>", "<0.512.0>", "<0.50.0>", "<0.12345.0>", "<0.600.0>"]
    end

    test "what the VM remarked on did not fail" do
      assert records() |> Report.filter_events(kind: :any, failed: true) |> pids() ==
               ["<0.512.0>", "<0.12345.0>"]
    end

    test "a limit is the most recent of what was asked for" do
      assert records() |> Report.filter_events(limit: 2) |> pids() ==
               ["<0.50.0>", "<0.12345.0>"]

      assert records() |> Report.filter_events(limit: 1, group: "MyApp.Worker") |> pids() ==
               ["<0.12345.0>"]

      assert records() |> Report.filter_events(limit: 100) |> length() == 4
      assert Report.filter_events(records(), limit: 0) == []
    end

    test "options are taken together" do
      assert records()
             |> Report.filter_events(
               since: "-1m",
               group: "MyApp.Worker",
               app: "my_app",
               failed: true,
               status: "RuntimeError",
               now: @now
             )
             |> pids() == ["<0.12345.0>"]
    end

    test "what is not an option is refused, and named" do
      assert_raise ArgumentError, ~r/:sinse is not an option here/, fn ->
        Report.filter_events(records(), sinse: "-1m")
      end

      assert_raise ArgumentError, ~r/:width is not an option here/, fn ->
        Report.filter_events(records(), width: 10)
      end

      assert_raise ArgumentError, "limit: -1 is not a count", fn ->
        Report.filter_events(records(), limit: -1)
      end

      assert_raise ArgumentError, "failed: \"yes\" is not true or false", fn ->
        Report.filter_events(records(), failed: "yes")
      end
    end

    test "nothing is what there is of nothing" do
      assert Report.filter_events([]) == []
      assert Report.filter_events([], since: "-1h", failed: true, limit: 3) == []
    end
  end

  describe "exits/2" do
    test "the processes that ended are a table, oldest first" do
      assert Report.exits(records()) == """
             ENDED                         PID  APP         STATUS         ELAPSED      REDS   PEAK MEM  PROCESS
             #{at(3000)}      <0.77.0>  my_app      normal             1ms         -          -  fn in MyApp.Foo.bar/2
             #{at(30)}     <0.512.0>  my_app      killed           394ms     48.1k    2.3 MiB  MyApp.Worker (MyApp.Worker.One)
             #{at(20)}      <0.50.0>  kernel      unknown         >40.0s      1.2M    700 MiB  code_server
             #{at(10)}   <0.12345.0>  my_app      RuntimeError     1m55s      5.5M    1.0 KiB  MyApp.Worker
             """
    end

    test "a record without figures has a dash for each" do
      bare = ended(60, %{"service" => "MyApp.Worker", "pid" => "<0.80.0>"})

      assert Report.exits([bare]) == """
             ENDED                         PID  APP         STATUS      ELAPSED      REDS   PEAK MEM  PROCESS
             #{at(60)}      <0.80.0>  my_app      normal            -         -          -  MyApp.Worker
             """
    end

    test "a process whose start is not known lived longer than it was seen to" do
      old =
        ended(60, %{
          "source" => "sampled",
          "service" => "MyApp.Cache",
          "status" => "unknown",
          "pid" => "<0.80.0>",
          "seen_seconds" => 7380.0,
          "reductions" => 900,
          "peak_memory_bytes" => 512
        })

      assert Report.exits([old]) == """
             ENDED                         PID  APP         STATUS      ELAPSED      REDS   PEAK MEM  PROCESS
             #{at(60)}      <0.80.0>  my_app      unknown      >2h03m       900      512 B  MyApp.Cache
             """
    end

    test "a name is shown with the group only if it is something else" do
      same = ended(2, %{"service" => "code_server", "name" => "code_server", "pid" => "<0.1.0>"})
      other = ended(1, %{"service" => "MyApp.Worker", "name" => "worker_1", "pid" => "<0.2.0>"})

      assert Report.exits([same, other]) == """
             ENDED                         PID  APP         STATUS      ELAPSED      REDS   PEAK MEM  PROCESS
             #{at(2)}       <0.1.0>  my_app      normal            -         -          -  code_server
             #{at(1)}       <0.2.0>  my_app      normal            -         -          -  MyApp.Worker (worker_1)
             """
    end

    test "a column is as wide as the widest thing in it" do
      wide =
        ended(1, %{
          "service" => "MyApp.Worker",
          "pid" => "<12345.123456.7>",
          "app" => "my_application_of_many_words",
          "status" => "FunctionClauseError",
          "elapsed_seconds" => 0.5
        })

      narrow = ended(2, %{"service" => "init", "pid" => "<0.0.0>", "app" => "none"})

      assert Report.exits([wide, narrow]) == """
             ENDED                             PID  APP                           STATUS                ELAPSED      REDS   PEAK MEM  PROCESS
             #{at(2)}           <0.0.0>  none                          normal                      -         -          -  init
             #{at(1)}  <12345.123456.7>  my_application_of_many_words  FunctionClauseError     500ms         -          -  MyApp.Worker
             """
    end

    test "widths are counted in characters as they are read, not in bytes" do
      # The second application is written with combining accents.
      composed = ended(2, %{"service" => "Überwachung", "pid" => "<0.1.0>", "app" => "größe"})

      combining =
        ended(1, %{"service" => "Élan", "pid" => "<0.2.0>", "app" => @combining})

      assert Report.exits([composed, combining]) == """
             ENDED                         PID  APP         STATUS      ELAPSED      REDS   PEAK MEM  PROCESS
             #{at(2)}       <0.1.0>  größe       normal            -         -          -  Überwachung
             #{at(1)}       <0.2.0>  #{@combining}      normal            -         -          -  Élan
             """
    end

    test "the last column is cut to the width asked for, and says that it was" do
      long = ended(2, %{"service" => "fn in MyApp.Foo.bar/2", "pid" => "<0.1.0>"})
      accented = ended(1, %{"service" => "Überwachung.Prüfer", "pid" => "<0.2.0>"})
      exact = ended(0, %{"service" => "MyApp.Worker", "pid" => "<0.3.0>"})

      assert Report.exits([long, accented, exact], width: 12) == """
             ENDED                         PID  APP         STATUS      ELAPSED      REDS   PEAK MEM  PROCESS
             #{at(2)}       <0.1.0>  my_app      normal            -         -          -  fn in MyApp…
             #{at(1)}       <0.2.0>  my_app      normal            -         -          -  Überwachung…
             #{at(0)}       <0.3.0>  my_app      normal            -         -          -  MyApp.Worker
             """

      assert Report.exits([long], width: 0) == Report.exits([long])
      assert Report.exits([long], width: 1) =~ "  …\n"
    end

    test "the options are those of filter_events" do
      assert Report.exits(records(), since: "-25s", failed: true, limit: 1, now: @now) == """
             ENDED                         PID  APP         STATUS         ELAPSED      REDS   PEAK MEM  PROCESS
             #{at(10)}   <0.12345.0>  my_app      RuntimeError     1m55s      5.5M    1.0 KiB  MyApp.Worker
             """

      assert_raise ArgumentError, ~r/is not a time/, fn ->
        Report.exits(records(), since: "yesterday", now: @now)
      end

      assert_raise ArgumentError, ~r/:by is not an option here/, fn ->
        Report.exits(records(), by: :app)
      end
    end

    test "what the VM remarked on has its kind for a status, and what was measured" do
      remarks = [
        ended(3, %{
          "kind" => "large_heap",
          "service" => "MyApp.Cache",
          "pid" => "<0.3.0>",
          "value" => 64 * 1024 * 1024,
          "unit" => "bytes"
        }),
        ended(2, %{
          "kind" => "long_message_queue",
          "service" => "MyApp.Inbox",
          "name" => "inbox",
          "pid" => "<0.4.0>",
          "value" => 12_400,
          "unit" => "messages"
        }),
        ended(1, %{"kind" => "busy_port", "service" => "MyApp.Socket", "pid" => "<0.5.0>"})
      ]

      assert Report.exits(records() ++ remarks, kind: :any, since: "-6s", now: @now) == """
             ENDED                         PID  APP         STATUS               ELAPSED      REDS   PEAK MEM  PROCESS
             #{at(5)}     <0.600.0>  my_app      long_gc                    -         -          -  MyApp.Worker  [120ms]
             #{at(3)}       <0.3.0>  my_app      large_heap                 -         -          -  MyApp.Cache  [64.0 MiB]
             #{at(2)}       <0.4.0>  my_app      long_message_queue         -         -          -  MyApp.Inbox (inbox)  [12.4k messages]
             #{at(1)}       <0.5.0>  my_app      busy_port                  -         -          -  MyApp.Socket
             """
    end

    test "of nothing, the table is its headers and says so" do
      expected = """
      ENDED                         PID  APP         STATUS      ELAPSED      REDS   PEAK MEM  PROCESS
      (none)
      """

      assert Report.exits([]) == expected
      assert Report.exits(records(), status: "timeout") == expected
    end
  end

  describe "summary/2" do
    test "the processes that ended are totalled by what they were, the busiest first" do
      assert Report.summary(records()) == """
             #{at(3000)} to #{at(10)}

                COUNT  FAILED       REDS    ELAPSED  PEAK MEM  GROUP
                    2       2       5.5M      1m55s   2.3 MiB  MyApp.Worker
                    1       0       1.2M     >40.0s   700 MiB  code_server
                    1       0          -        1ms         -  fn in MyApp.Foo.bar/2
                    4       2       6.7M     >2m35s   700 MiB  (all 3 groups)
             """
    end

    test "or by the application they ran in" do
      assert Report.summary(records(), by: :app) == """
             #{at(3000)} to #{at(10)}

                COUNT  FAILED       REDS    ELAPSED  PEAK MEM  APP
                    3       2       5.5M      1m55s   2.3 MiB  my_app
                    1       0       1.2M     >40.0s   700 MiB  kernel
                    4       2       6.7M     >2m35s   700 MiB  (all 2 applications)
             """
    end

    test "the time is what was asked for, where it was asked for" do
      assert Report.summary(records(), since: "-1h", until: "now", now: @now) == """
             #{at(3600)} to #{at(0)}

                COUNT  FAILED       REDS    ELAPSED  PEAK MEM  GROUP
                    2       2       5.5M      1m55s   2.3 MiB  MyApp.Worker
                    1       0       1.2M     >40.0s   700 MiB  code_server
                    1       0          -        1ms         -  fn in MyApp.Foo.bar/2
                    4       2       6.7M     >2m35s   700 MiB  (all 3 groups)
             """

      assert Report.summary(records(), since: "-25s", now: @now) == """
             #{at(25)} to #{at(10)}

                COUNT  FAILED       REDS    ELAPSED  PEAK MEM  GROUP
                    1       1       5.5M      1m55s   1.0 KiB  MyApp.Worker
                    1       0       1.2M     >40.0s   700 MiB  code_server
                    2       1       6.7M     >2m35s   700 MiB  (all 2 groups)
             """
    end

    test "one group is its own total" do
      assert Report.summary(records(), group: "MyApp.Worker") == """
             #{at(30)} to #{at(10)}

                COUNT  FAILED       REDS    ELAPSED  PEAK MEM  GROUP
                    2       2       5.5M      1m55s   2.3 MiB  MyApp.Worker
             """
    end

    test "groups that did the same work are in the order of their names" do
      events =
        for {name, ago} <- [{"c", 3}, {"a", 2}, {"b", 1}] do
          ended(ago, %{"service" => name, "pid" => "<0.#{ago}.0>", "reductions" => 10})
        end

      assert Report.summary(events) == """
             #{at(3)} to #{at(1)}

                COUNT  FAILED       REDS    ELAPSED  PEAK MEM  GROUP
                    1       0         10          -         -  a
                    1       0         10          -         -  b
                    1       0         10          -         -  c
                    3       0         30          -         -  (all 3 groups)
             """
    end

    test "the total is of every group, however many are listed" do
      assert Report.summary(records(), n: 1, width: 10) == """
             #{at(3000)} to #{at(10)}

                COUNT  FAILED       REDS    ELAPSED  PEAK MEM  GROUP
                    2       2       5.5M      1m55s   2.3 MiB  MyApp.Wor…
                    4       2       6.7M     >2m35s   700 MiB  (all 3 gr…
             """
    end

    test "a record with no application is totalled under a dash" do
      event = ended(1, %{"service" => "init", "pid" => "<0.0.0>"})
      event = %{event | fields: Map.delete(event.fields, "app")}

      assert Report.summary([event], by: :app) == """
             #{at(1)} to #{at(1)}

                COUNT  FAILED       REDS    ELAPSED  PEAK MEM  APP
                    1       0          -          -         -  -
             """
    end

    test "of nothing, the table is its headers" do
      assert Report.summary([]) == """
                COUNT  FAILED       REDS    ELAPSED  PEAK MEM  GROUP
             """

      assert Report.summary(records(), status: "timeout", since: "-1m", until: "now", now: @now) ==
               """
               #{at(60)} to #{at(0)}

                  COUNT  FAILED       REDS    ELAPSED  PEAK MEM  GROUP
               """
    end

    test "what is not a way of totalling is refused" do
      assert_raise ArgumentError, "by: :user is not :group or :app", fn ->
        Report.summary(records(), by: :user)
      end

      assert_raise ArgumentError, ~r/is not a time/, fn ->
        Report.summary(records(), until: "soon", now: @now)
      end
    end
  end

  # As the Rust's tests have it: every process lived a second and a half,
  # and started `id` nanoseconds after the job did.
  defp span(id, parent, name, changes \\ []) do
    span = %Span{
      trace_id: <<1::128>>,
      span_id: <<id::64>>,
      parent_span_id: parent && <<parent::64>>,
      name: name,
      service: "my_app",
      ok: true,
      ending: "exited normal",
      start_ns: trunc(@now) * 1_000_000_000 + id,
      duration_ns: 1_500_000_000,
      attributes: %{
        "process.pid" => "<0.#{id}.0>",
        "process.reductions" => 12_400,
        "process.peak_memory_bytes" => 10_485_760
      }
    }

    struct!(span, changes)
  end

  defp failed(span), do: %{span | ok: false, ending: "crashed: RuntimeError"}

  # A job of one process, in a trace of its own, that started `ago`
  # seconds before now.
  defp job(trace, ago, name, changes \\ []) do
    span(1, nil, name, changes)
    |> Map.merge(%{
      trace_id: <<trace::128>>,
      start_ns: trunc(@now - ago) * 1_000_000_000,
      attributes: %{}
    })
  end

  defp jobs do
    [
      job(2, 60, "MyApp.Import"),
      job(1, 3000, "MyApp.Export", service: "other_app"),
      failed(job(3, 10, "MyApp.Import"))
    ]
  end

  @trace_1 "(trace 00000000000000000000000000000001)"
  @trace_2 "(trace 00000000000000000000000000000002)"
  @trace_3 "(trace 00000000000000000000000000000003)"

  describe "trees/2" do
    test "a job is drawn as the tree it was" do
      spans = [
        span(1, nil, "MyApp.Build"),
        span(2, 1, "MyApp.Compiler"),
        span(3, 2, "fn in MyApp.Compiler.parse/1"),
        failed(span(4, 1, "MyApp.Compiler")),
        span(5, 1, "MyApp.Linker")
      ]

      assert Report.trees(spans) == """
             #{at(0)}  5 processes over 1.5s, 62.0k reductions, 1 failed  in my_app  #{@trace_1}
               MyApp.Build  1.5s, 12.4k reductions, 10.0 MiB
               ├─ MyApp.Compiler  1.5s, 12.4k reductions, 10.0 MiB
               │  └─ fn in MyApp.Compiler.parse/1  1.5s, 12.4k reductions, 10.0 MiB
               ├─ MyApp.Compiler  1.5s, 12.4k reductions, 10.0 MiB  [crashed: RuntimeError]
               └─ MyApp.Linker  1.5s, 12.4k reductions, 10.0 MiB

             """
    end

    test "the spans may be given in any order: children are in the order they started" do
      spans = [
        span(5, 1, "MyApp.Linker"),
        span(3, 2, "fn in MyApp.Compiler.parse/1"),
        span(2, 1, "MyApp.Compiler"),
        span(1, nil, "MyApp.Build"),
        span(4, 3, "MyApp.Lexer")
      ]

      assert Report.trees(spans) == """
             #{at(0)}  5 processes over 1.5s, 62.0k reductions  in my_app  #{@trace_1}
               MyApp.Build  1.5s, 12.4k reductions, 10.0 MiB
               ├─ MyApp.Compiler  1.5s, 12.4k reductions, 10.0 MiB
               │  └─ fn in MyApp.Compiler.parse/1  1.5s, 12.4k reductions, 10.0 MiB
               │     └─ MyApp.Lexer  1.5s, 12.4k reductions, 10.0 MiB
               └─ MyApp.Linker  1.5s, 12.4k reductions, 10.0 MiB

             """
    end

    test "a job whose processes were started by one that is not part of it has a root for each" do
      # Each is the child of a process that has not ended.
      spans = [
        span(1, 99, "MyApp.Reader", service: "reader_app"),
        span(2, 99, "MyApp.Writer", service: "writer_app"),
        span(3, 2, "MyApp.Flusher")
      ]

      assert Report.trees(spans) == """
             #{at(0)}  3 processes over 1.5s, 37.2k reductions  in reader_app  #{@trace_1}
               MyApp.Reader  1.5s, 12.4k reductions, 10.0 MiB
               MyApp.Writer  1.5s, 12.4k reductions, 10.0 MiB
               └─ MyApp.Flusher  1.5s, 12.4k reductions, 10.0 MiB

             """
    end

    test "a process whose parent is missing is a root, beside the root there is" do
      spans = [
        span(1, nil, "MyApp.Build"),
        span(2, 1, "MyApp.Compiler"),
        span(3, 42, "MyApp.Orphan"),
        # The store writes "no parent" as all zeroes.
        span(4, 0, "MyApp.Other")
      ]

      assert Report.trees(spans) == """
             #{at(0)}  4 processes over 1.5s, 49.6k reductions  in my_app  #{@trace_1}
               MyApp.Build  1.5s, 12.4k reductions, 10.0 MiB
               └─ MyApp.Compiler  1.5s, 12.4k reductions, 10.0 MiB
               MyApp.Orphan  1.5s, 12.4k reductions, 10.0 MiB
               MyApp.Other  1.5s, 12.4k reductions, 10.0 MiB

             """
    end

    test "a long job is cut short and says so" do
      spans = [span(1, nil, "MyApp.Build") | for(id <- 2..100, do: span(id, 1, "MyApp.Worker"))]
      lines = spans |> Report.trees(max_lines: 10) |> String.split("\n")

      assert length(lines) == 1 + 11 + 2
      assert Enum.at(lines, 1) == "  MyApp.Build  1.5s, 12.4k reductions, 10.0 MiB"
      assert Enum.at(lines, 10) == "  ├─ MyApp.Worker  1.5s, 12.4k reductions, 10.0 MiB"
      assert Enum.at(lines, 11) == "  … and 90 more"
      assert Enum.slice(lines, 12, 2) == ["", ""]

      assert spans |> Report.trees() |> String.split("\n") |> Enum.at(61) == "  … and 40 more"
      assert spans |> Report.trees(max_lines: 0) |> String.split("\n") |> length() == 1 + 100 + 2
    end

    test "a job is cut short in the middle of a branch" do
      spans = [
        span(1, nil, "MyApp.Build"),
        span(2, 1, "MyApp.Compiler"),
        span(3, 2, "MyApp.Lexer"),
        span(4, 2, "MyApp.Parser"),
        span(5, 1, "MyApp.Linker")
      ]

      assert Report.trees(spans, max_lines: 3) == """
             #{at(0)}  5 processes over 1.5s, 62.0k reductions  in my_app  #{@trace_1}
               MyApp.Build  1.5s, 12.4k reductions, 10.0 MiB
               ├─ MyApp.Compiler  1.5s, 12.4k reductions, 10.0 MiB
               │  ├─ MyApp.Lexer  1.5s, 12.4k reductions, 10.0 MiB
               … and 2 more

             """
    end

    test "what a process was is shown no wider than asked" do
      long = "fn in MyApp.Compiler." <> String.duplicate("very_", 40) <> "long/1"
      accented = "Überwachung.Prüfer.Größe"
      spans = [span(1, nil, long, attributes: %{}), span(2, 1, accented, attributes: %{})]

      assert Report.trees(spans, width: 20) == """
             #{at(0)}  2 processes over 1.5s  in my_app  #{@trace_1}
               fn in MyApp.Compile…  1.5s
               └─ Überwachung.Prüfer.…  1.5s

             """

      assert Report.trees(spans, width: 24) =~ "└─ Überwachung.Prüfer.Größe  1.5s\n"
      assert Report.trees(spans, width: 23) =~ "└─ Überwachung.Prüfer.Grö…  1.5s\n"

      # A hundred unless asked, and all of it if none is.
      assert Report.trees(spans) =~ "  " <> String.slice(long, 0, 99) <> "…  1.5s\n"
      assert Report.trees(spans, width: 0) =~ "  " <> long <> "  1.5s\n"
    end

    test "a process has the figures its span has" do
      spans = [
        span(1, nil, "MyApp.Build", attributes: %{"process.reductions" => 999}),
        span(2, 1, "MyApp.Compiler", attributes: %{"process.peak_memory_bytes" => 512}),
        span(3, 1, "MyApp.Linker", attributes: %{}, duration_ns: 234_000_000),
        failed(span(4, 1, "MyApp.Packer", attributes: %{}, duration_ns: 0))
      ]

      assert Report.trees(spans) == """
             #{at(0)}  4 processes over 1.5s, 999 reductions, 1 failed  in my_app  #{@trace_1}
               MyApp.Build  1.5s, 999 reductions
               ├─ MyApp.Compiler  1.5s, 512 B
               ├─ MyApp.Linker  234ms
               └─ MyApp.Packer  0ms  [crashed: RuntimeError]

             """
    end

    test "a process whose start is not known lived longer than its span" do
      spans = [
        span(1, nil, "MyApp.Supervisor", attributes: %{"process.start_known" => false}),
        span(2, 1, "MyApp.Worker", attributes: %{"process.start_known" => true})
      ]

      assert Report.trees(spans) == """
             #{at(0)}  2 processes over 1.5s  in my_app  #{@trace_1}
               MyApp.Supervisor  >1.5s
               └─ MyApp.Worker  1.5s

             """
    end

    test "a process that ended in a way that is not known did not fail" do
      spans = [span(1, nil, "MyApp.Build", ok: nil, ending: "", attributes: %{})]

      assert Report.trees(spans) == """
             #{at(0)}  1 process over 1.5s  in my_app  #{@trace_1}
               MyApp.Build  1.5s

             """
    end

    test "a job lasts from its first start to its last end" do
      start = trunc(@now) * 1_000_000_000

      spans = [
        span(1, nil, "MyApp.Build", start_ns: start, duration_ns: 1_000_000, attributes: %{}),
        span(2, 1, "MyApp.Late",
          start_ns: start + 200_000_000,
          duration_ns: 34_000_000,
          attributes: %{}
        )
      ]

      assert Report.trees(spans) == """
             #{at(0)}  2 processes over 234ms  in my_app  #{@trace_1}
               MyApp.Build  1ms
               └─ MyApp.Late  34ms

             """
    end

    test "there is a tree for each trace, oldest first" do
      assert Report.trees(jobs()) == """
             #{at(3000)}  1 process over 1.5s  in other_app  #{@trace_1}
               MyApp.Export  1.5s

             #{at(60)}  1 process over 1.5s  in my_app  #{@trace_2}
               MyApp.Import  1.5s

             #{at(10)}  1 process over 1.5s, 1 failed  in my_app  #{@trace_3}
               MyApp.Import  1.5s  [crashed: RuntimeError]

             """
    end

    test "since and until are by when the first process of the job started" do
      assert Report.trees(jobs(), since: "-60s", now: @now) == """
             #{at(60)}  1 process over 1.5s  in my_app  #{@trace_2}
               MyApp.Import  1.5s

             #{at(10)}  1 process over 1.5s, 1 failed  in my_app  #{@trace_3}
               MyApp.Import  1.5s  [crashed: RuntimeError]

             """

      assert Report.trees(jobs(), until: "-1m", since: "-5m", now: @now) == """
             #{at(60)}  1 process over 1.5s  in my_app  #{@trace_2}
               MyApp.Import  1.5s

             """

      # A process of the job that started later does not bring the job in.
      late = %{span(2, 1, "MyApp.Late") | trace_id: <<1::128>>}
      assert Report.trees([late | jobs()], since: "-5s", now: @now) == "(none)\n"
    end

    test "a group is what any process of the job was" do
      spans = [span(2, 1, "MyApp.Child", trace_id: <<2::128>>, attributes: %{}) | jobs()]

      assert Report.trees(spans, group: "MyApp.Child") == """
             #{at(60)}  2 processes over 1m01s  in my_app  #{@trace_2}
               MyApp.Import  1.5s
               └─ MyApp.Child  1.5s

             """

      assert Report.trees(spans, group: MyApp.Export) == """
             #{at(3000)}  1 process over 1.5s  in other_app  #{@trace_1}
               MyApp.Export  1.5s

             """
    end

    test "an application is what any process of the job ran in" do
      assert Report.trees(jobs(), app: "other_app") == """
             #{at(3000)}  1 process over 1.5s  in other_app  #{@trace_1}
               MyApp.Export  1.5s

             """

      assert Report.trees(jobs(), app: "no_app") == "(none)\n"
    end

    test "failed is the jobs in which something failed" do
      assert Report.trees(jobs(), failed: true) == """
             #{at(10)}  1 process over 1.5s, 1 failed  in my_app  #{@trace_3}
               MyApp.Import  1.5s  [crashed: RuntimeError]

             """
    end

    test "a limit is the most recent jobs, and says how many came before" do
      assert Report.trees(jobs(), limit: 2) == """
             (1 earlier job)

             #{at(60)}  1 process over 1.5s  in my_app  #{@trace_2}
               MyApp.Import  1.5s

             #{at(10)}  1 process over 1.5s, 1 failed  in my_app  #{@trace_3}
               MyApp.Import  1.5s  [crashed: RuntimeError]

             """

      assert Report.trees(jobs(), limit: 1, app: "my_app") =~ ~r/\A\(1 earlier job\)\n\n/
      assert Report.trees(jobs(), limit: 1) =~ ~r/\A\(2 earlier jobs\)\n\n/
      assert Report.trees(jobs(), limit: 3) == Report.trees(jobs())
    end

    test "of nothing, there is none" do
      assert Report.trees([]) == "(none)\n"
    end

    test "what is not an option is refused" do
      assert_raise ArgumentError, ~r/:status is not an option here/, fn ->
        Report.trees(jobs(), status: "killed")
      end

      assert_raise ArgumentError, ~r/is not a time/, fn ->
        Report.trees(jobs(), since: "yesterday", now: @now)
      end

      assert_raise ArgumentError, "max_lines: :all is not a count", fn ->
        Report.trees(jobs(), max_lines: :all)
      end
    end
  end

  defp process(pid, name, changes) do
    Map.merge(
      %{
        pid: pid,
        name: name,
        app: "my_app",
        registered: false,
        age_seconds: 115.0,
        age_known: true,
        reductions: 5_500_000,
        reductions_per_sec: 48_100.0,
        work_pct: 12.4,
        memory_bytes: 2_202_009,
        message_queue_len: 0
      },
      Map.new(changes)
    )
  end

  defp snapshot(processes) do
    %{
      ts: @now,
      host: "ohm",
      node: "app@ohm",
      vm: %{
        processes: 182,
        run_queue: 0,
        scheduler_util_pct: 6.1,
        memory_total_bytes: 137_000_000,
        reductions_per_sec: 48_100.0
      },
      processes: processes
    }
  end

  defp several do
    [
      process("<0.512.0>", "MyApp.Worker", registered: true),
      process("<0.50.0>", "code_server",
        app: "kernel",
        registered: true,
        age_seconds: 4000.0,
        age_known: false,
        reductions_per_sec: nil,
        work_pct: nil,
        memory_bytes: 700_000,
        message_queue_len: 3
      ),
      process("<0.700.0>", "fn in MyApp.Foo.bar/2",
        age_seconds: 0.5,
        reductions_per_sec: 1_200_000.0,
        work_pct: 80.0,
        memory_bytes: 3 * 1024 * 1024 * 1024,
        message_queue_len: 12_400
      ),
      process("<0.90.0>", "MyApp.Idle",
        age_seconds: 86_400.0,
        reductions_per_sec: 0.0,
        work_pct: 0.0,
        memory_bytes: 2_000,
        message_queue_len: 1
      )
    ]
  end

  # The rows of a table, by what is last on each.
  defp order(rendered) do
    rendered
    |> String.split("\n", trim: true)
    |> Enum.drop(3)
    |> Enum.map(&(&1 |> String.split("  ") |> List.last()))
  end

  describe "top/2" do
    test "the processes of a moment are a table under what the VM was doing" do
      assert Report.top(snapshot([process("<0.512.0>", "MyApp.Worker", registered: true)])) ==
               """
               #{at(0)}  app@ohm  (182 processes)
               run queue 0   schedulers 6.1%   mem 131 MiB   48.1k reductions/s

                        PID  APP           WORK%    REDS/s     MEMORY   MSGQ       AGE  PROCESS
                  <0.512.0>  my_app         12.4     48.1k    2.1 MiB      0     1m55s  MyApp.Worker
               """
    end

    test "those doing the most are first, and those with no rate yet are last" do
      assert Report.top(snapshot(several())) == """
             #{at(0)}  app@ohm  (182 processes)
             run queue 0   schedulers 6.1%   mem 131 MiB   48.1k reductions/s

                      PID  APP           WORK%    REDS/s     MEMORY   MSGQ       AGE  PROCESS
                <0.700.0>  my_app         80.0      1.2M    3.0 GiB  12.4k     500ms  fn in MyApp.Foo.bar/2
                <0.512.0>  my_app         12.4     48.1k    2.1 MiB      0     1m55s  MyApp.Worker
                 <0.90.0>  my_app          0.0         0    2.0 KiB      1     1d00h  MyApp.Idle
                 <0.50.0>  kernel            -         -    684 KiB      3    >1h06m  code_server
             """
    end

    test "or those with the most memory, the longest queue, or the greatest age" do
      assert several() |> snapshot() |> Report.top(sort: :work) |> order() ==
               ["fn in MyApp.Foo.bar/2", "MyApp.Worker", "MyApp.Idle", "code_server"]

      assert several() |> snapshot() |> Report.top(sort: :memory) |> order() ==
               ["fn in MyApp.Foo.bar/2", "MyApp.Worker", "code_server", "MyApp.Idle"]

      assert several() |> snapshot() |> Report.top(sort: :queue) |> order() ==
               ["fn in MyApp.Foo.bar/2", "code_server", "MyApp.Idle", "MyApp.Worker"]

      # The one that was running before anyone listened is older than it
      # was seen to be, and comes first.
      assert several() |> snapshot() |> Report.top(sort: :age) |> order() ==
               ["code_server", "MyApp.Idle", "MyApp.Worker", "fn in MyApp.Foo.bar/2"]

      assert_raise ArgumentError, "sort: :cpu is not :work, :memory, :queue, or :age", fn ->
        Report.top(snapshot(several()), sort: :cpu)
      end
    end

    test "equals are in the order of their pids, as numbers" do
      processes =
        for pid <- ["<0.1000.0>", "<0.99.0>", "<0.512.0>"], do: process(pid, "worker #{pid}", [])

      assert processes |> snapshot() |> Report.top() |> order() ==
               ["worker <0.99.0>", "worker <0.512.0>", "worker <0.1000.0>"]
    end

    test "as many are shown as are asked for, and twenty if none are" do
      assert several() |> snapshot() |> Report.top(n: 2) |> order() ==
               ["fn in MyApp.Foo.bar/2", "MyApp.Worker"]

      many = for id <- 1..30, do: process("<0.#{id}.0>", "MyApp.Worker", [])
      assert many |> snapshot() |> Report.top() |> order() |> length() == 20
      assert many |> snapshot() |> Report.top(n: 25) |> order() |> length() == 25
    end

    test "an application or a group is matched exactly" do
      assert several() |> snapshot() |> Report.top(app: "kernel") |> order() == ["code_server"]

      assert several() |> snapshot() |> Report.top(group: "MyApp.Idle") |> order() ==
               ["MyApp.Idle"]

      assert several() |> snapshot() |> Report.top(group: MyApp.Idle, app: "my_app") |> order() ==
               ["MyApp.Idle"]

      # A process that has a group is known by it, whatever its name.
      named = [process("<0.1.0>", "worker_1", group: "MyApp.Worker") | several()]

      assert named |> snapshot() |> Report.top(group: "MyApp.Worker") |> order() ==
               ["worker_1", "MyApp.Worker"]
    end

    test "a part of the second line that has no value is left out" do
      processes = [process("<0.512.0>", "MyApp.Worker", [])]

      row =
        "   <0.512.0>  my_app         12.4     48.1k    2.1 MiB      0     1m55s  MyApp.Worker"

      header = "         PID  APP           WORK%    REDS/s     MEMORY   MSGQ       AGE  PROCESS"

      vm = %{processes: 182, run_queue: 3, scheduler_util_pct: nil, reductions_per_sec: 999.5}

      assert Report.top(%{snapshot(processes) | vm: vm}) == """
             #{at(0)}  app@ohm  (182 processes)
             run queue 3   999.5 reductions/s

             #{header}
             #{row}
             """

      assert Report.top(%{snapshot(processes) | vm: %{memory_total_bytes: 1024}}) == """
             #{at(0)}  app@ohm  (1 process)
             mem 1.0 KiB

             #{header}
             #{row}
             """

      assert Report.top(%{ts: @now, host: "ohm", processes: processes}) == """
             #{at(0)}  ohm  (1 process)

             #{header}
             #{row}
             """
    end

    test "columns are as wide as the widest thing in them, in characters" do
      processes = [
        process("<12345.123456.7>", "Überwachung",
          app: "größere_anwendung",
          work_pct: 100.0,
          reductions_per_sec: 999.96
        ),
        process("<0.1.0>", "init", app: @combining, reductions_per_sec: 12.5)
      ]

      assert Report.top(%{ts: @now, processes: processes}) == """
             #{at(0)}  (2 processes)

                          PID  APP                  WORK%    REDS/s     MEMORY   MSGQ       AGE  PROCESS
             <12345.123456.7>  größere_anwendung    100.0      1.0k    2.1 MiB      0     1m55s  Überwachung
                      <0.1.0>  #{@combining}                12.4      12.5    2.1 MiB      0     1m55s  init
             """
    end

    test "of no processes, the table is its headers and says so" do
      assert Report.top(snapshot([])) == """
             #{at(0)}  app@ohm  (182 processes)
             run queue 0   schedulers 6.1%   mem 131 MiB   48.1k reductions/s

                      PID  APP           WORK%    REDS/s     MEMORY   MSGQ       AGE  PROCESS
             (none)
             """

      assert Report.top(snapshot(several()), app: "no_app") =~ ~r/PROCESS\n\(none\)\n\z/
    end
  end
end
