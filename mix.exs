defmodule TimelessBeamAcct.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/awksedgreep/timeless_beam_acct"

  def project do
    [
      app: :timeless_beam_acct,
      version: @version,
      # 1.18 for the JSON module: this package has no dependencies, so it
      # can be loaded into a node that was built without it.
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      deps: deps(),
      description:
        "BEAM process accounting history in Timeless: VM statistics, series for " <>
          "applications and processes, and an exit record for every process that ends.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      # ssl is asked for only by an https plane, and is started then. A
      # release that has no use for it need not carry it.
      extra_applications: [:logger, public_key: :optional, ssl: :optional],
      mod: {TimelessBeamAcct.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # For `mix igniter.install` and nothing else. A collector has no
      # dependencies when it runs, which is what lets it be sent to a node
      # that is already running.
      {:igniter, "~> 0.6", optional: true},
      # For the page in LiveDashboard, which is compiled only where these
      # are: an application without Phoenix fetches neither.
      {:phoenix_live_dashboard, "~> 0.8", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Mark Cotner"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # docs/ is how the project is worked on (the plan of the page, what is
      # run before a release), and not what it is used by: it stays in the
      # repository.
      files: ~w(lib .formatter.exs mix.exs README.md DESIGN.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "DESIGN.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end
