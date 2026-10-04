if Code.ensure_loaded?(Phoenix.LiveDashboard.Router) do
  defmodule TimelessBeamAcct.Dashboard.Router do
    @moduledoc """
    LiveDashboard with the page of recordings, in one line. Compiled only
    where LiveDashboard is.

        defmodule MyAppWeb.Router do
          use Phoenix.Router
          import TimelessBeamAcct.Dashboard.Router

          scope "/" do
            pipe_through :browser
            timeless_beam_acct_dashboard "/dashboard"
          end
        end

    `:live_dashboard` is merged into what `live_dashboard` is given.
    """

    @doc "LiveDashboard at `path`, with the page of recordings under `beam`."
    defmacro timeless_beam_acct_dashboard(path, opts \\ []) do
      quote bind_quoted: [path: path, opts: opts] do
        import Phoenix.LiveDashboard.Router

        extra = Keyword.get(opts, :live_dashboard, [])

        live_dashboard(
          path,
          [
            live_session_name: :timeless_beam_acct_dashboard,
            additional_pages: [beam: TimelessBeamAcct.Dashboard.Page]
          ] ++ extra
        )
      end
    end
  end
end
