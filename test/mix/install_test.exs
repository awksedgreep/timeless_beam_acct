defmodule Mix.Tasks.TimelessBeamAcct.InstallTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.TimelessBeamAcct.Install

  defp files(config \\ "import Config\n", more \\ %{}) do
    Map.merge(
      %{
        "mix.exs" => """
        defmodule Demo.MixProject do
          use Mix.Project
          def project, do: [app: :demo, version: "0.1.0", elixir: "~> 1.18", deps: []]
          def application, do: [mod: {Demo.Application, []}]
        end
        """,
        "lib/demo/application.ex" => """
        defmodule Demo.Application do
          use Application

          def start(_type, _args) do
            children = [Demo.Worker]
            Supervisor.start_link(children, strategy: :one_for_one)
          end
        end
        """,
        "config/config.exs" => config,
        ".formatter.exs" => "[]\n"
      },
      more
    )
  end

  defp install(argv, files \\ files()) do
    [app_name: :demo, files: files]
    |> Igniter.Test.test_project()
    |> Igniter.Mix.Task.configure_and_run(Install, argv)
  end

  defp content(igniter, path) do
    case igniter.rewrite.sources[path] do
      nil -> nil
      source -> Rewrite.Source.get(source, :content)
    end
  end

  # What the configuration written says, as the application would read it.
  defp configured(igniter, path) do
    path
    |> Config.Reader.eval!(igniter |> content(path) |> without_imports(), env: :dev)
    |> Keyword.get(:timeless_beam_acct, [])
  end

  defp without_imports(content),
    do: content |> String.split("\n") |> Enum.reject(&(&1 =~ "import_config")) |> Enum.join("\n")

  test "a collector is started with the application, and not with its tests" do
    igniter = install(~w(--always-on))

    assert igniter.issues == []
    assert configured(igniter, "config/config.exs") == [start: true, sink: :http]
    assert configured(igniter, "config/test.exs") == [start: false]
    # The tests' configuration is read, or it says nothing.
    assert content(igniter, "config/config.exs") =~ "import_config"
  end

  test "what is written is what a collector can be started with" do
    igniter = install(~w(--always-on --sink stdout))
    options = igniter |> configured("config/config.exs") |> Keyword.delete(:start)

    assert %TimelessBeamAcct.Options{sink: {TimelessBeamAcct.Sink.Stdout, []}} =
             TimelessBeamAcct.Options.new!(options)
  end

  test "for the stores in the node, the collector is put among the children, after them" do
    igniter = install(~w(--always-on --sink timeless))

    assert igniter.issues == []
    application = content(igniter, "lib/demo/application.ex")

    assert application =~
             ~r/children = \[\s*Demo\.Worker,\s*\{TimelessBeamAcct, \[?sink: :timeless\]?\}\s*\]/

    # It is not started from the configuration as well: it would be
    # started before the stores are, and the application would not start.
    assert configured(igniter, "config/config.exs") == []
    # And it is kept from starting with the tests, child though it is.
    assert configured(igniter, "config/test.exs") == [start: false]

    assert [notice] = igniter.notices
    assert notice =~ "stores in the node"
    assert notice =~ "among the children"
  end

  test "for the stores in the node, the collector comes after timeless_phoenix's, which is put first" do
    application = """
    defmodule Demo.Application do
      use Application

      def start(_type, _args) do
        children = [
          {TimelessPhoenix, [data_dir: "priv/observability"]},
          DemoWeb.Telemetry,
          {Phoenix.PubSub, name: Demo.PubSub},
          # Start to serve requests, typically the last entry
          DemoWeb.Endpoint
        ]

        Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Supervisor)
      end
    end
    """

    igniter =
      install(
        ~w(--always-on --sink timeless),
        files("import Config\n", %{"lib/demo/application.ex" => application})
      )

    assert igniter.issues == []
    written = content(igniter, "lib/demo/application.ex")

    assert written =~
             ~r/\{TimelessPhoenix, .*DemoWeb\.Endpoint,\s*\{TimelessBeamAcct, \[?sink: :timeless\]?\}\s*\]/s
  end

  test "for the stores in the node, a collector that is among the children is left as it is" do
    application = """
    defmodule Demo.Application do
      use Application

      def start(_type, _args) do
        children = [
          {TimelessPhoenix, [data_dir: "priv/observability", name: :obs]},
          {TimelessBeamAcct, sink: {:timeless, metrics: :tp_obs_timeless}}
        ]

        Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Supervisor)
      end
    end
    """

    igniter =
      install(
        ~w(--always-on --sink timeless),
        files("import Config\n", %{"lib/demo/application.ex" => application})
      )

    assert igniter.issues == []
    assert content(igniter, "lib/demo/application.ex") == application
  end

  test "for the stores in the node, it says which store, and what to write for another" do
    igniter = install(~w(--always-on --sink timeless))

    assert [notice] = igniter.notices
    assert notice =~ ":tp_default_timeless"
    assert notice =~ "{TimelessBeamAcct, sink: {:timeless, metrics: :tp_obs_timeless}}"
    assert String.replace(notice, ~r/\s+/, " ") =~ "It is off while the tests run"
  end

  test "the planes are where they are said to be" do
    igniter =
      install(~w(--always-on --metrics-url http://planes:8428 --traces-url http://planes:10428))

    assert configured(igniter, "config/config.exs") == [
             start: true,
             sink: :http,
             metrics_url: "http://planes:8428",
             traces_url: "http://planes:10428"
           ]

    options =
      igniter
      |> configured("config/config.exs")
      |> Keyword.delete(:start)
      |> TimelessBeamAcct.Options.new!()

    assert {TimelessBeamAcct.Sink.Http, sink} = options.sink
    assert sink[:metrics_url] == "http://planes:8428"
  end

  test "what is there already is left as it is" do
    config = """
    import Config
    config :timeless_beam_acct, start: false, sink: :stdout, min_age: 5
    """

    igniter = install(~w(--always-on --sink http), files(config))

    assert configured(igniter, "config/config.exs") == [start: false, sink: :stdout, min_age: 5]
  end

  test "the application's supervisor is not touched" do
    igniter = install(~w(--always-on))
    assert content(igniter, "lib/demo/application.ex") == files()["lib/demo/application.ex"]
  end

  test "it says what was turned on, and how to turn it off" do
    igniter = install(~w(--always-on))

    assert [notice] = igniter.notices
    assert notice =~ "every process that starts and ends"
    assert notice =~ "TimelessBeamAcct.check()"
    assert notice =~ "config :timeless_beam_acct, start: false"
    assert notice =~ "Timeless planes"
  end

  test "a sink that is not one is refused, and nothing is written" do
    igniter = install(~w(--always-on --sink prometheus))

    assert [issue] = igniter.issues
    assert issue == "--sink is prometheus: expected one of http, timeless, stdout"
    assert content(igniter, "config/config.exs") == "import Config\n"
    assert content(igniter, "config/test.exs") == nil
  end

  test "where the planes are is not said to another sink" do
    igniter = install(~w(--always-on --sink timeless --logs-url http://planes:9428))

    assert [issue] = igniter.issues
    assert issue == "--logs-url is an option of the http sink, and the sink is timeless"
    assert content(igniter, "config/config.exs") == "import Config\n"
  end

  describe "the page in LiveDashboard" do
    defp router(body) do
      files(
        "import Config\n",
        %{
          "lib/demo_web/router.ex" => """
          defmodule DemoWeb.Router do
            use Phoenix.Router

          #{body}
          end
          """
        }
      )
    end

    defp routed(igniter), do: content(igniter, "lib/demo_web/router.ex")
    defp page_config(igniter), do: configured(igniter, "config/config.exs")[:dashboard]

    # As `mix phx.new` writes it.
    @generated """
      if Application.compile_env(:demo, :dev_routes) do
        import Phoenix.LiveDashboard.Router

        scope "/dev" do
          pipe_through :browser

          live_dashboard "/dashboard", metrics: DemoWeb.Telemetry
        end
      end
    """

    test "is added to the dashboard mix phx.new makes, with where the planes are" do
      igniter = install([], router(@generated))

      assert igniter.issues == []

      assert routed(igniter) =~
               ~s|live_dashboard("/dashboard",\n|

      assert routed(igniter) =~ "metrics: DemoWeb.Telemetry,"
      assert routed(igniter) =~ "additional_pages: [beam: TimelessBeamAcct.Dashboard.Page]"

      assert page_config(igniter) == [
               metrics_url: "http://127.0.0.1:8428",
               logs_url: "http://127.0.0.1:9428",
               traces_url: "http://127.0.0.1:10428"
             ]

      assert Enum.any?(igniter.notices, &(&1 =~ "TimelessAcct"))
      assert Enum.any?(igniter.notices, &(&1 =~ "Securing it"))
    end

    test "the planes the collector is told of are the page's" do
      igniter = install(~w(--logs-url http://planes:9428), router(@generated))
      assert page_config(igniter)[:logs_url] == "http://planes:9428"
      assert page_config(igniter)[:metrics_url] == "http://127.0.0.1:8428"
    end

    test "is put beside the pages a dashboard has" do
      igniter =
        install(
          [],
          router(~s|  live_dashboard "/dashboard", additional_pages: [other: Demo.OtherPage]|)
        )

      assert routed(igniter) =~ "other: Demo.OtherPage"
      assert routed(igniter) =~ "beam: TimelessBeamAcct.Dashboard.Page"
    end

    test "is given to a dashboard with no options" do
      igniter = install([], router(~s|  live_dashboard "/dashboard"|))
      assert routed(igniter) =~ "additional_pages: [beam: TimelessBeamAcct.Dashboard.Page]"
    end

    test "is added once, however often the installer runs" do
      once = install([], router(@generated))

      twice =
        install(
          [],
          router(routed(once) |> String.split("\n") |> Enum.slice(3..-3//1) |> Enum.join("\n"))
        )

      assert length(Regex.scan(~r/TimelessBeamAcct.Dashboard.Page/, routed(twice))) == 1
      assert Enum.any?(twice.notices, &(&1 =~ "has the page of recordings already"))
    end

    test "is not put among pages that are not written out" do
      body = ~s|  live_dashboard "/dashboard", additional_pages: Demo.pages()|
      igniter = install([], router(body))

      assert routed(igniter) == router(body)["lib/demo_web/router.ex"]
      assert page_config(igniter) == nil
      assert Enum.any?(igniter.notices, &(&1 =~ ~r/not\s+written out as a list/))
    end

    test "timeless_phoenix's dashboard is left as it is, and the page is configured" do
      body = """
        import TimelessPhoenix.Router

        scope "/" do
          pipe_through :browser
          timeless_phoenix_dashboard("/dashboard")
        end
      """

      igniter = install([], router(body))

      assert routed(igniter) == router(body)["lib/demo_web/router.ex"]
      assert page_config(igniter)[:logs_url] == "http://127.0.0.1:9428"
      assert Enum.any?(igniter.notices, &(&1 =~ "timeless_phoenix's dashboard"))
    end

    test "a router with no dashboard is left as it is, and says how" do
      body = ~s|  scope "/" do\n    get "/", DemoWeb.PageController, :home\n  end|
      igniter = install([], router(body))

      assert routed(igniter) == router(body)["lib/demo_web/router.ex"]
      assert page_config(igniter) == nil
      assert Enum.any?(igniter.notices, &(&1 =~ "No LiveDashboard was found"))
    end

    test "an application with no router hears nothing of it" do
      igniter = install([])
      refute Enum.any?(igniter.notices, &(&1 =~ "No LiveDashboard was found"))
    end
  end

  describe "without --always-on" do
    test "nothing is collected: no collector is configured, and none is a child" do
      igniter = install([])

      assert igniter.issues == []
      assert configured(igniter, "config/config.exs") == []
      assert content(igniter, "config/test.exs") == nil
      assert content(igniter, "lib/demo/application.ex") == files()["lib/demo/application.ex"]
    end

    test "with a dashboard, only the page and where the planes are" do
      igniter = install(~w(--metrics-url http://planes:8428), router(@generated))

      assert Keyword.keys(configured(igniter, "config/config.exs")) == [:dashboard]
      assert page_config(igniter)[:metrics_url] == "http://planes:8428"
    end

    test "it says how a recording is started, and that it ends by itself" do
      igniter = install([])

      assert [notice] = igniter.notices
      assert notice =~ "collects nothing until a recording is started"
      assert notice =~ "mix timeless_beam_acct.record NODE --for 1h"
      assert notice =~ "--always-on"
    end

    test "a sink is refused: it is where a collector that is always on writes" do
      igniter = install(~w(--sink timeless))

      assert [issue] = igniter.issues
      assert issue =~ "--always-on"
      assert content(igniter, "config/config.exs") == "import Config\n"
      assert content(igniter, "lib/demo/application.ex") == files()["lib/demo/application.ex"]
    end
  end

  test "the installer is not among what is sent to a running node" do
    refute Install in TimelessBeamAcct.Remote.modules()
    refute Enum.any?(TimelessBeamAcct.Remote.modules(), &(Atom.to_string(&1) =~ "Igniter"))
  end
end
