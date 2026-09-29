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
    igniter = install([])

    assert igniter.issues == []
    assert configured(igniter, "config/config.exs") == [start: true, sink: :http]
    assert configured(igniter, "config/test.exs") == [start: false]
    # The tests' configuration is read, or it says nothing.
    assert content(igniter, "config/config.exs") =~ "import_config"
  end

  test "what is written is what a collector can be started with" do
    igniter = install(~w(--sink stdout))
    options = igniter |> configured("config/config.exs") |> Keyword.delete(:start)

    assert %TimelessBeamAcct.Options{sink: {TimelessBeamAcct.Sink.Stdout, []}} =
             TimelessBeamAcct.Options.new!(options)
  end

  test "for the stores in the node, the collector is put among the children, after them" do
    igniter = install(~w(--sink timeless))

    assert igniter.issues == []
    application = content(igniter, "lib/demo/application.ex")

    assert application =~
             ~r/children = \[\s*Demo\.Worker,\s*\{TimelessBeamAcct, \[?sink: :timeless\]?\}\s*\]/

    # It is not started from the configuration as well: it would be
    # started before the stores are, and the application would not start.
    assert configured(igniter, "config/config.exs") == []
    assert content(igniter, "config/test.exs") == nil

    assert [notice] = igniter.notices
    assert notice =~ "stores in the node"
    assert notice =~ "among the children"
  end

  test "the planes are where they are said to be" do
    igniter =
      install(~w(--metrics-url http://planes:8428 --traces-url http://planes:10428))

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

    igniter = install(~w(--sink http), files(config))

    assert configured(igniter, "config/config.exs") == [start: false, sink: :stdout, min_age: 5]
  end

  test "the application's supervisor is not touched" do
    igniter = install([])
    assert content(igniter, "lib/demo/application.ex") == files()["lib/demo/application.ex"]
  end

  test "it says what was turned on, and how to turn it off" do
    igniter = install([])

    assert [notice] = igniter.notices
    assert notice =~ "every process that starts and ends"
    assert notice =~ "TimelessBeamAcct.check()"
    assert notice =~ "config :timeless_beam_acct, start: false"
    assert notice =~ "Timeless planes"
  end

  test "a sink that is not one is refused, and nothing is written" do
    igniter = install(~w(--sink prometheus))

    assert [issue] = igniter.issues
    assert issue == "--sink is prometheus: expected one of http, timeless, stdout"
    assert content(igniter, "config/config.exs") == "import Config\n"
    assert content(igniter, "config/test.exs") == nil
  end

  test "where the planes are is not said to another sink" do
    igniter = install(~w(--sink timeless --logs-url http://planes:9428))

    assert [issue] = igniter.issues
    assert issue == "--logs-url is an option of the http sink, and the sink is timeless"
    assert content(igniter, "config/config.exs") == "import Config\n"
  end

  test "the installer is not among what is sent to a running node" do
    refute Install in TimelessBeamAcct.Remote.modules()
    refute Enum.any?(TimelessBeamAcct.Remote.modules(), &(Atom.to_string(&1) =~ "Igniter"))
  end
end
