defmodule TimelessBeamAcct.Dashboard.RecordingFromPageTest do
  # Not with the others: a collector hears of every process of the node.
  use ExUnit.Case, async: false

  alias TimelessBeamAcct.Dashboard.Page

  @moduletag :capture_log

  setup do
    Application.put_env(:timeless_beam_acct, :dashboard,
      metrics_url: "http://127.0.0.1:1",
      logs_url: "http://127.0.0.1:1",
      traces_url: "http://127.0.0.1:1",
      timeout: 1
    )

    on_exit(fn ->
      Application.delete_env(:timeless_beam_acct, :dashboard)
      if TimelessBeamAcct.Remote.attached?(node()), do: TimelessBeamAcct.Remote.detach(node())
    end)
  end

  defp socket do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, page: %{node: node()}, said: nil}}
  end

  test "a recording is started from the page, made longer, and stopped" do
    params = %{
      "length" => "other",
      "other" => "20m",
      "processes" => "false",
      "failed_only" => "true"
    }

    {:noreply, socket} = Page.handle_event("record", params, socket())
    assert socket.assigns.said == "Recording."

    assert %{recording: recording, options: options} = TimelessBeamAcct.status()
    assert_in_delta recording.stop_at - recording.started, 1200.0, 0.01
    assert recording.by =~ "LiveDashboard"
    # What was asked for in the form is what the collector was told.
    assert options.max_processes == 0
    assert options.records == :abnormal
    {TimelessBeamAcct.Sink.Http, sink} = options.sink
    assert sink[:logs_url] == "http://127.0.0.1:1"

    # The page shows it, and no form to start another.
    assert socket.assigns.running.recording == recording.recording

    # A second is refused, and the page says why.
    {:noreply, again} = Page.handle_event("record", %{"length" => "1h"}, socket)
    assert again.assigns.said =~ "It could not be started"

    {:noreply, socket} = Page.handle_event("extend", %{"by" => "1h"}, socket)
    assert socket.assigns.said =~ "It now ends at"
    assert_in_delta TimelessBeamAcct.status().recording.stop_at - recording.started, 4800.0, 0.01

    {:noreply, socket} = Page.handle_event("stop", %{}, socket)
    assert socket.assigns.said == "The recording was stopped."
    refute TimelessBeamAcct.running?()
    assert socket.assigns.running == nil
  end

  test "what is not a length is refused, and nothing is started" do
    {:noreply, socket} =
      Page.handle_event("record", %{"length" => "other", "other" => "soon"}, socket())

    assert socket.assigns.said =~ "It could not be started"
    refute TimelessBeamAcct.running?()

    {:noreply, socket} =
      Page.handle_event("record", %{"length" => "other", "other" => "2d"}, socket())

    assert socket.assigns.said =~ "at most"
    refute TimelessBeamAcct.running?()
  end
end
