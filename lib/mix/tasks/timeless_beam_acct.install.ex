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
    3. Adds the page of recordings ("TimelessAcct") to the
       `live_dashboard` in the router, and says where the planes are for
       it: `config :timeless_beam_acct, :dashboard, ...`. A router with
       timeless_phoenix's dashboard is left as it is, since that has the
       page among its own; a dashboard whose `additional_pages` are not
       a list written out is left as it is, and what to add is said
    4. Says what was turned on, and how to see that it is working

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
          |> dashboard(urls)

        true ->
          igniter
          |> configure("config.exs", :start, true)
          |> configure("config.exs", :sink, String.to_atom(sink))
          |> configure_urls(urls)
          |> configure("test.exs", :start, false)
          |> Igniter.add_notice(notice(sink))
          |> dashboard(urls)
      end
    end

    ## The page in LiveDashboard

    @page TimelessBeamAcct.Dashboard.Page
    # As it is written in a router: the alias, not the atom.
    @page_code {:__aliases__, [], [:TimelessBeamAcct, :Dashboard, :Page]}
    @default_urls [
      metrics_url: "http://127.0.0.1:8428",
      logs_url: "http://127.0.0.1:9428",
      traces_url: "http://127.0.0.1:10428"
    ]

    # The page of recordings, into the dashboard the router has: one of
    # timeless_phoenix's, which has it already, or a `live_dashboard`,
    # which is told of it. And where the planes are, which the page reads.
    defp dashboard(igniter, urls) do
      {igniter, found} = find_dashboard(igniter)

      case found do
        :no_router ->
          igniter

        :none ->
          Igniter.add_notice(igniter, page_notice(:none))

        {:live_dashboard, router} ->
          {igniter, outcome} = add_to_live_dashboards(igniter, router)

          igniter
          |> configure_page(urls, outcome == :added)
          |> Igniter.add_notice(page_notice(outcome))

        found ->
          igniter
          |> configure_page(urls, true)
          |> Igniter.add_notice(page_notice(found))
      end
    end

    defp find_dashboard(igniter) do
      with {igniter, router} when router != nil <- Igniter.Libs.Phoenix.select_router(igniter),
           {:ok, {igniter, _source, zipper}} <-
             Igniter.Project.Module.find_module(igniter, router) do
        has? = fn name ->
          match?({:ok, _}, Igniter.Code.Common.move_to(zipper, &call?(&1, name)))
        end

        cond do
          has?.(:timeless_beam_acct_dashboard) -> {igniter, :own}
          has?.(:timeless_phoenix_dashboard) -> {igniter, :timeless_phoenix}
          has?.(:live_dashboard) -> {igniter, {:live_dashboard, router}}
          true -> {igniter, :none}
        end
      else
        {igniter, nil} -> {igniter, :no_router}
        {:error, igniter} -> {igniter, :no_router}
      end
    end

    defp call?(zipper, name), do: Igniter.Code.Function.function_call?(zipper, name, [1, 2])

    # Each `live_dashboard` without the page is given it, among its
    # `additional_pages`. One whose pages are not a list written out, as
    # `additional_pages: pages()`, is not changed: what is in it is not
    # known here.
    defp add_to_live_dashboards(igniter, router) do
      {:ok, {igniter, _source, zipper}} = Igniter.Project.Module.find_module(igniter, router)

      dashboards =
        zipper
        |> Igniter.Code.Common.find_all(&call?(&1, :live_dashboard))
        |> Enum.map(&state_of/1)

      cond do
        Enum.all?(dashboards, &(&1 == :has)) ->
          {igniter, :already}

        Enum.any?(dashboards, &(&1 == :opaque)) and not Enum.any?(dashboards, &(&1 == :add)) ->
          {igniter, :opaque}

        true ->
          {:ok, igniter} =
            Igniter.Project.Module.find_and_update_module(igniter, router, fn zipper ->
              Igniter.Code.Common.update_all_matches(
                zipper,
                &(call?(&1, :live_dashboard) and state_of(&1) == :add),
                &put_page/1
              )
            end)

          {igniter, :added}
      end
    end

    defp state_of(call) do
      with {:ok, options} <- Igniter.Code.Function.move_to_nth_argument(call, 1) do
        cond do
          Igniter.Code.Keyword.keyword_has_path?(options, [:additional_pages, :beam]) ->
            :has

          match?({:ok, _}, Igniter.Code.Keyword.get_key(options, :additional_pages)) ->
            {:ok, pages} = Igniter.Code.Keyword.get_key(options, :additional_pages)

            if Igniter.Code.List.list?(
                 Igniter.Code.Common.maybe_move_to_single_child_block(pages)
               ),
               do: :add,
               else: :opaque

          Igniter.Code.List.list?(Igniter.Code.Common.maybe_move_to_single_child_block(options)) ->
            :add

          true ->
            :opaque
        end
      else
        # `live_dashboard "/dashboard"`, with no options.
        :error -> :add
      end
    end

    defp put_page(call) do
      case Igniter.Code.Function.move_to_nth_argument(call, 1) do
        {:ok, _} ->
          Igniter.Code.Function.update_nth_argument(call, 1, fn options ->
            Igniter.Code.Keyword.put_in_keyword(options, [:additional_pages, :beam], @page_code)
          end)

        :error ->
          Igniter.Code.Function.append_argument(call, additional_pages: [beam: @page_code])
      end
    end

    # Where the planes are, for the page: where the collector writes, if
    # that was said, and where the planes are unless told otherwise.
    defp configure_page(igniter, _urls, false), do: igniter

    defp configure_page(igniter, urls, true) do
      Enum.reduce(@default_urls, igniter, fn {key, default}, igniter ->
        Igniter.Project.Config.configure_new(
          igniter,
          "config.exs",
          :timeless_beam_acct,
          [:dashboard, key],
          urls[key] || default
        )
      end)
    end

    defp page_notice(:added) do
      """
      The page of recordings is added to the LiveDashboard in the router,
      as "TimelessAcct", among its additional_pages. It reads the planes
      said in config :timeless_beam_acct, :dashboard (config/config.exs).

      Anyone who can open the dashboard can record any node connected to
      this one: the README has how to keep it to those who should
      ("Securing it").
      """
    end

    defp page_notice(:timeless_phoenix) do
      """
      The router has timeless_phoenix's dashboard, which has the page of
      recordings ("TimelessAcct") among its own from timeless_phoenix
      2.0.4. It reads the planes said in
      config :timeless_beam_acct, :dashboard (config/config.exs).
      """
    end

    defp page_notice(:own) do
      """
      The router has timeless_beam_acct_dashboard already, with the page of
      recordings. Where the planes are is in
      config :timeless_beam_acct, :dashboard (config/config.exs).
      """
    end

    defp page_notice(:already) do
      """
      The LiveDashboard in the router has the page of recordings already.
      Where the planes are is in
      config :timeless_beam_acct, :dashboard (config/config.exs).
      """
    end

    defp page_notice(:opaque) do
      """
      The LiveDashboard in the router has additional_pages that are not
      written out as a list, so the page of recordings was not added. Add
      it among them:

          beam: #{inspect(@page)}

      and say where the planes are:

          config :timeless_beam_acct, :dashboard,
            metrics_url: "http://127.0.0.1:8428",
            logs_url: "http://127.0.0.1:9428",
            traces_url: "http://127.0.0.1:10428"
      """
    end

    defp page_notice(:none) do
      """
      No LiveDashboard was found in the router, so the page of recordings
      was not added. In an application with phoenix_live_dashboard, it is one
      of the dashboard's pages:

          live_dashboard "/dashboard",
            additional_pages: [beam: #{inspect(@page)}]
      """
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
