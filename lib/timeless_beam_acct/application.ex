defmodule TimelessBeamAcct.Application do
  @moduledoc """
  Starts a collector with the application, if one was asked for.

  A collector asks the VM for word of every process that starts and ends.
  That is not something to begin doing to a node because a package was
  added to it, so nothing is collected unless the configuration says
  `start: true`:

      config :timeless_beam_acct,
        start: true,
        sink: :http,
        metrics_url: "http://127.0.0.1:8428"

  Everything beside `:start` is an option of `TimelessBeamAcct.Options`.
  A collector can as well be started where the application's own
  processes are, as `{TimelessBeamAcct, options}` among the children of a
  supervisor.
  """

  use Application

  @impl true
  def start(_type, _args) do
    env = Application.get_all_env(:timeless_beam_acct)

    children =
      if Keyword.get(env, :start, false),
        do: [{TimelessBeamAcct, Keyword.delete(env, :start)}],
        else: []

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: TimelessBeamAcct.Application.Supervisor
    )
  end
end
