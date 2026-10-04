defmodule TimelessBeamAcct.Dashboard.PageTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias TimelessBeamAcct.Dashboard.Page

  @now 1_791_000_000.0

  defp page(assigns) do
    %{
      node: :app@ohm,
      now: @now,
      said: nil,
      running: nil,
      collecting: false,
      waiting: nil,
      links: %{},
      estimate: nil,
      recordings: [],
      error: nil
    }
    |> Map.merge(Map.new(assigns))
    |> Page.render()
    |> rendered_to_string()
  end

  test "it is a page of LiveDashboard's, and is named in the menu" do
    assert {:ok, "TimelessAcct"} = Page.menu_link(%{}, %{})
    assert function_exported?(Page, :__page_live__, 1)
  end

  test "a recording that is running has how far along it is, and what to do about it" do
    html =
      page(
        running: %{started: @now - 1800, stop_at: @now + 1800, by: "mark@ohm", recording: "abc"}
      )

    assert html =~ "Recording app@ohm"
    assert html =~ "by mark@ohm"
    assert html =~ "30m00s recorded"
    assert html =~ "30m00s left"
    assert html =~ "width: 50.0%"
    assert html =~ ~s(phx-click="stop")
    assert html =~ ~s(phx-value-by="1h")
    refute html =~ "No recording is running"
  end

  test "with none running, a recording can be started" do
    html = page([])
    assert html =~ "Record app@ohm"
    assert html =~ ~s(phx-submit="record")
    for {value, _} <- Page.lengths(), do: assert(html =~ ~s(value="#{value}"))
    assert html =~ ~s(name="other")
    assert html =~ ~s(name="start_at")
    assert html =~ "a day at most"
    assert html =~ "about 5% of one core where 65 processes end"
    measured = page(estimate: "This node starts about 90 processes a second.")
    assert measured =~ "This node starts about 90 processes a second."
    refute measured =~ "where 65 processes end"
    # Not where a collector is running already.
    refute page(collecting: true) =~ ~s(phx-submit="record")
    assert html =~ "No recordings in the last 31 days."
  end

  test "a recording that is waiting to begin says when" do
    html =
      page(
        collecting: true,
        waiting: %{start_at: @now + 3600, stop_after: 5400.0, by: "mark@ohm"}
      )

    assert html =~ "app@ohm is to be recorded"
    assert html =~ "for 1h30m"
    assert html =~ "Call it off"
    refute html =~ "and is not a recording"
    refute html =~ ~s(phx-submit="record")
  end

  test "a collector that is not a recording is said to be one" do
    html = page(collecting: true)
    assert html =~ "A collector is running in <strong>app@ohm</strong>, and is not a recording"
    refute html =~ "No recording is running"
  end

  test "the recordings, with how each ended" do
    recordings = [
      %{
        id: "aaaaaaaaaaaa",
        node: "app@ohm",
        host: "ohm",
        started: @now - 600,
        stop_at: @now + 3000,
        ended: nil,
        reason: nil,
        by: nil
      },
      %{
        id: "bbbbbbbbbbbb",
        node: "jobs@ohm",
        host: "ohm",
        started: @now - 9000,
        stop_at: @now - 5400,
        ended: @now - 5400,
        reason: "time",
        by: "mark@ohm"
      },
      %{
        id: "cccccccccccc",
        node: "jobs@ohm",
        host: "ohm",
        started: @now - 20000,
        stop_at: @now - 16400,
        ended: @now - 19000,
        reason: "stopped",
        by: nil
      },
      %{
        id: "dddddddddddd",
        node: "jobs@ohm",
        host: "ohm",
        started: @now - 90000,
        stop_at: @now - 86400,
        ended: nil,
        reason: nil,
        by: nil
      }
    ]

    html = page(recordings: recordings)
    assert html =~ "10m00s so far"
    assert html =~ ~s(badge badge-danger">recording)
    assert html =~ "its time ran out"
    assert html =~ "it was stopped"
    assert html =~ "its node ended first"
    assert html =~ ~r/>\s*bbbbbbbb\s*</
    refute html =~ "No recordings"
  end

  test "what could not be read, and what was done, are said" do
    html =
      page(error: "http://127.0.0.1:1: connection refused", said: "The recording was stopped.")

    assert html =~ "connection refused"
    assert html =~ "The recording was stopped."
  end
end
