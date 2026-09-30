if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.TimelessBeamAcct.Install do
    @shortdoc "Installs TimelessBeamAcct into your application."
    @moduledoc """
    #{@shortdoc}

    Configures a collector to start with the application, and to stay off
    while the application's tests run.

    ## Usage

        mix igniter.install timeless_beam_acct
        mix igniter.install timeless_beam_acct --sink timeless
        mix igniter.install timeless_beam_acct --metrics-url http://planes:8428

    ## Options

      * `--sink`: `http` (the default), `timeless`, or `stdout`. `http` is
        the Timeless planes, which is what a canvas reads. `timeless` is
        the Timeless stores in the node, for an application that has them
        through `timeless_phoenix`.
      * `--metrics-url`, `--logs-url`, `--traces-url`: where the planes
        are, if they are not on this host at the ports they keep unless
        told.

    ## What it does

    1. Adds `config :timeless_beam_acct, start: true, sink: ...` to
       `config.exs`
    2. Adds `config :timeless_beam_acct, start: false` to `test.exs`
    3. Says what was turned on, and how to see that it is working

    What is there already is left as it is: an application that has said
    `start: false` has said so for a reason.

    With `--sink timeless` it does otherwise, and adds
    `{TimelessBeamAcct, sink: :timeless}` to the children of the
    application's supervisor, after those that are there. The stores in
    the node are children of the application, and have to be running
    when the collector starts. A collector started from the configuration
    starts before any of them, and the application would not start at
    all.

    `timeless_phoenix`'s installer puts `{TimelessPhoenix, ...}` first
    among the children, and this one puts the collector last, so the
    order is right whichever of the two is run first. It was run so
    against an application made by `mix phx.new`, with `timeless_phoenix`
    2.0.3.

    The metrics store written to is `:tp_default_timeless`, which is the
    one `timeless_phoenix` starts unless it is given a `:name`. An
    application that gave it one, as `{TimelessPhoenix, name: :obs, ...}`,
    has the store `:tp_obs_timeless`, and the child is changed by hand to
    say so:

        {TimelessBeamAcct, sink: {:timeless, metrics: :tp_obs_timeless}}

    Until it is, the application does not start, and the error says
    which store is running.

    A child of the application is started wherever the application is,
    its tests among the rest. So `config :timeless_beam_acct, start: false`
    is added to `test.exs` for this sink as for the others: a collector
    that is told so by the configuration does not start, though it is
    among the children.

    ## Igniter

    `mix igniter.install` adds Igniter for as long as it runs and takes it
    out again. `mix timeless_beam_acct.install`, run by itself, needs
    Igniter to be among the application's dependencies:

        {:igniter, "~> 0.6", only: [:dev, :test], runtime: false}

    ## Why the configuration, and not the supervision tree

    A collector asks the VM for word of every process that starts and
    ends, and sends what it hears to the planes. A child of the
    application's supervisor would do that while the tests run too, and
    the planes on a developer's machine would fill with the processes of
    a test suite. In the configuration it is on where it is wanted and off
    where it is not.

    A bearer token is not asked for here, since what is written is
    committed. It belongs in `runtime.exs`:

        config :timeless_beam_acct, token: System.fetch_env!("TIMELESS_TOKEN")
    """

    use Igniter.Mix.Task

    @sinks ~w(http timeless stdout)
    @urls [:metrics_url, :logs_url, :traces_url]

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :timeless_beam_acct,
        schema: [sink: :string, metrics_url: :string, logs_url: :string, traces_url: :string],
        defaults: [sink: "http"],
        required: [],
        positional: [],
        aliases: [],
        composes: [],
        installs: [],
        adds_deps: [],
        example: "mix igniter.install timeless_beam_acct --sink timeless"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      sink = options[:sink] || "http"
      urls = for key <- @urls, url = options[key], do: {key, url}

      cond do
        sink not in @sinks ->
          Igniter.add_issue(
            igniter,
            "--sink is #{sink}: expected one of #{Enum.join(@sinks, ", ")}"
          )

        urls != [] and sink != "http" ->
          [{key, _} | _] = urls

          Igniter.add_issue(
            igniter,
            "--#{key |> Atom.to_string() |> String.replace("_", "-")} is an option of the " <>
              "http sink, and the sink is #{sink}"
          )

        sink == "timeless" ->
          igniter
          |> Igniter.Project.Application.add_new_child(
            {TimelessBeamAcct, {:code, Sourceror.parse_string!("[sink: :timeless]")}},
            after: fn _child -> true end
          )
          |> configure("test.exs", :start, false)
          |> Igniter.add_notice(notice(sink))

        true ->
          igniter
          |> configure("config.exs", :start, true)
          |> configure("config.exs", :sink, String.to_atom(sink))
          |> configure_urls(urls)
          |> configure("test.exs", :start, false)
          |> Igniter.add_notice(notice(sink))
      end
    end

    defp configure(igniter, file, key, value),
      do: Igniter.Project.Config.configure_new(igniter, file, :timeless_beam_acct, [key], value)

    defp configure_urls(igniter, urls) do
      Enum.reduce(urls, igniter, fn {key, url}, igniter ->
        configure(igniter, "config.exs", key, url)
      end)
    end

    defp notice(sink) do
      """
      TimelessBeamAcct is configured to start with the application.

      A collector hears from the VM of every process that starts and ends,
      and sweeps the processes every ten seconds. #{where(sink)}

      From a shell on the node, to see that it is working:

          TimelessBeamAcct.check()
          TimelessBeamAcct.top()

      #{how_off(sink)}
      """
    end

    defp how_off("timeless") do
      """
      It is among the children of the application's supervisor, after the
      stores it writes to. It is off while the tests run (config/test.exs).
      To turn it off anywhere else:

          config :timeless_beam_acct, start: false

      Samples go to the store :tp_default_timeless, which is the one
      timeless_phoenix starts unless it is given a :name. For
      {TimelessPhoenix, name: :obs, ...} the store is :tp_obs_timeless,
      and the child is to be changed to say so:

          {TimelessBeamAcct, sink: {:timeless, metrics: :tp_obs_timeless}}
      """
    end

    defp how_off(_sink) do
      """
      It is off while the tests run (config/test.exs). To turn it off
      anywhere else:

          config :timeless_beam_acct, start: false
      """
    end

    defp where("http"),
      do: "What it records goes to the Timeless planes, which a canvas reads."

    defp where("timeless"),
      do: "What it records goes to the Timeless stores in the node."

    defp where("stdout"),
      do: "What it records is printed, which is for looking at what a collector sees."
  end
else
  defmodule Mix.Tasks.TimelessBeamAcct.Install do
    @shortdoc "Installs TimelessBeamAcct (requires igniter)."
    @moduledoc @shortdoc
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'timeless_beam_acct.install' requires igniter.
      Please install igniter and try again.

          {:igniter, "~> 0.6", only: [:dev]}

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
