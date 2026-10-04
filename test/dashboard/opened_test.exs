defmodule TimelessBeamAcct.Dashboard.OpenedTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias TimelessBeamAcct.{Clock, Watch, Watched}
  alias TimelessBeamAcct.Dashboard.Opened
  alias TimelessBeamAcct.Watch.Data

  defp watch(more \\ []) do
    now = Clock.now()

    store =
      struct!(
        %Watched.Store{
          range: {now - 7200, now - 5},
          series: Data.series(Watched.samples()),
          history: [{now - 20, 1.0}, {now - 10, 2.0}],
          timeline: {[{now - 600, 5.0}, {now - 300, 9.5}], 10.0},
          incidents: [%{at: now - 450, error: true}]
        },
        more
      )

    {:ok, watch} = Watch.new(store: store, at: "-10m")
    Watch.read_moment(%{watch | columns: Opened.columns() + 2})
  end

  defp html(watch),
    do: render_component(&Opened.recording/1, watch: watch, back: "/dashboard/beam")

  test "the keys of the browser are watch's keys" do
    assert Opened.key("ArrowLeft", false) == :left
    assert Opened.key("ArrowLeft", true) == {:shift, :left}
    assert Opened.key("ArrowRight", true) == {:shift, :right}
    assert Opened.key("Enter", false) == :enter
    assert Opened.key("Escape", false) == :esc
    assert Opened.key("PageDown", false) == :page_down
    assert Opened.key(",", false) == {:char, ","}
    assert Opened.key("/", false) == {:char, "/"}
    # What is not one of them is nothing.
    assert Opened.key("Shift", false) == nil
    assert Opened.key("F5", false) == nil
  end

  test "a key does to the page what it does in the terminal" do
    watch = watch()
    at = watch.state.at
    # A moment the store sampled: back by a reading, or by a minute.
    left = Opened.pressed(watch, :left).state.at
    assert left < at and left >= at - 20

    back = Opened.pressed(watch, {:char, ","}).state.at
    assert back <= at - 60 and back > at - 80
    assert Opened.pressed(watch, {:char, "4"}).state.tab == :exits
    assert Opened.tab(watch, "2").state.tab == :processes
    assert Opened.tab(watch, "9").state.tab == :groups
  end

  test "a column of the timeline is a moment to go to" do
    watch = watch()
    {from, to} = watch.detail.window
    gone = Opened.go_to_column(watch, 0)
    assert_in_delta gone.state.at, from + (to - from) / Opened.columns() / 2, 10
    assert Opened.go_to_column(gone, Opened.columns() - 1).state.at > gone.state.at
  end

  test "the page's own views: the node, what the VM remarked on, and the collector" do
    remark =
      TimelessBeamAcct.Watch.Store.exit(Clock.now() - 700, "notice", %{
        "kind" => "long_gc",
        "service" => "MyApp.Importer",
        "pid" => "<0.902.0>",
        "status" => "long_gc",
        "value" => 340,
        "unit" => "ms"
      })

    watch = watch(remarks: [remark])
    assert Opened.extra("5") == :node
    assert Opened.extra("6") == :remarks
    assert Opened.extra("7") == :collector
    assert Opened.extra("1") == nil

    node = Opened.read_extra(watch, :node)
    assert [%{label: "schedulers", kind: :pct, points: [_ | _]} | _] = node

    html =
      render_component(&Opened.recording/1,
        watch: watch,
        back: "/",
        extra: :node,
        extra_data: node
      )

    assert html =~ "schedulers: <strong>2.0%</strong>"
    assert html =~ "garbage collections /s"
    # watch's view is not drawn under the page's own.
    refute html =~ "GROUP"

    remarks = Opened.read_extra(watch, :remarks)
    assert [%{status: "long_gc"}] = remarks

    html =
      render_component(&Opened.recording/1,
        watch: watch,
        back: "/",
        extra: :remarks,
        extra_data: remarks
      )

    assert html =~ "MyApp.Importer"
    assert html =~ "340ms"

    html =
      render_component(&Opened.recording/1,
        watch: watch,
        back: "/",
        extra: :remarks,
        extra_data: []
      )

    assert html =~ "The VM remarked on nothing"

    collector = [{"beam_acct_processes", 512.0}, {"beam_acct_records_dropped", 0.0}]

    html =
      render_component(&Opened.recording/1,
        watch: watch,
        back: "/",
        extra: :collector,
        extra_data: collector
      )

    assert html =~ "beam_acct_processes"
    assert html =~ "<td>512</td>"

    html =
      render_component(&Opened.recording/1,
        watch: watch,
        back: "/",
        extra: :collector,
        extra_data: {:error, "the store is away"}
      )

    assert html =~ "the store is away"
  end

  test "it is drawn as watch's screen is" do
    html = html(watch())
    assert html =~ ~s(phx-window-keydown="key")
    assert html =~ "◀ "
    assert html =~ "run queue 2"
    assert html =~ "MyApp.Repo"
    assert html =~ "1 Groups"
    assert html =~ "MyApp.Repo work, the 10m00s before"
    # A column to click for each part of the stretch, and what went wrong marked.
    assert length(Regex.scan(~r/phx-click="goto"/, html)) == Opened.columns()
    assert html =~ ~s(fill="#c33")
    assert html =~ ~s(href="/dashboard/beam")

    exits = html(Opened.tab(watch(), "4"))
    assert exits =~ "PEAK MEM"
    jobs = html(Opened.tab(watch(), "3"))
    assert jobs =~ "No jobs in the quarter of an hour before"
  end
end
