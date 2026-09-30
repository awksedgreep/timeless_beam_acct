defmodule Mix.Tasks.TimelessBeamAcct.WatchTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.TimelessBeamAcct.Watch
  alias TimelessBeamAcct.TestPlane

  test "what is not understood is said, and nothing is watched" do
    assert_raise Mix.Error, ~r/--sorted is not understood/, fn -> Watch.run(["--sorted", "x"]) end
    assert_raise Mix.Error, ~r/One node at a time/, fn -> Watch.run(["a@b", "c@d"]) end

    assert_raise Mix.Error, ~r/--view is units: expected one of groups, processes/, fn ->
      Watch.run(["--view", "units", "--metrics-url", "http://127.0.0.1:1"])
    end

    assert_raise Mix.Error, ~r/Which node, or which store\?/, fn -> Watch.run([]) end

    assert_raise Mix.Error, ~r/http:\/\/127.0.0.1:1: connection refused/, fn ->
      Watch.run(["--metrics-url", "http://127.0.0.1:1", "--print", "80x20"])
    end
  end

  test "a store is drawn once, as text, of the node that was said" do
    sample = fn name, labels, value ->
      %{
        "metric" => Map.merge(%{"__name__" => name, "node" => "app@ohm"}, labels),
        "value" => [1, value]
      }
    end

    plane =
      start_supervised!(
        {TestPlane,
         answer: fn request ->
           case URI.parse(request.path).path do
             "/api/v1/label/node/values" ->
               {200, ~s({"status":"success","data":["app@ohm","other@ohm"]})}

             "/api/v1/query" ->
               if request.path =~ "metric=" do
                 {200, ~s({"timestamp":#{System.os_time(:second) - 5},"value":1.0})}
               else
                 {200,
                  JSON.encode!(%{
                    "status" => "success",
                    "data" => %{
                      "result" => [
                        sample.("beam_vm_run_queue", %{}, "3"),
                        sample.("beam_group_processes", %{"group" => "MyApp.Repo"}, "1"),
                        sample.("beam_group_work_pct", %{"group" => "MyApp.Repo"}, "41.5")
                      ]
                    }
                  })}
               end

             _ ->
               {200, ""}
           end
         end}
      )

    url = TestPlane.url(plane)

    printed =
      capture_io(fn ->
        Watch.run(["--metrics-url", url, "--node", "app@ohm", "--print", "90x16"])
      end)

    assert printed =~ "┌ timeless-beam-acct app@ohm"
    assert printed =~ "● LIVE"
    assert printed =~ "run queue 3"
    assert printed =~ ~r/MyApp.Repo\s+41.5/

    # Of a store with several, the node is to be said.
    assert_raise Mix.Error, ~r/one is to be said with --node: app@ohm, other@ohm/, fn ->
      Watch.run(["--metrics-url", url, "--print", "90x16"])
    end
  end
end
