defmodule Mix.Tasks.TimelessBeamAcct.Watch do
  @shortdoc "Watch a node in a terminal: now, and at any moment the store holds"

  @moduledoc """
  Watch a node in a terminal, as `timeless-acct watch` watches a host:
  the same screen, and the same keys.

      mix timeless_beam_acct.watch app@ohm --cookie secret
      mix timeless_beam_acct.watch app@ohm --at "2026-09-29 03:12" --view jobs
      mix timeless_beam_acct.watch --metrics-url http://127.0.0.1:8428 --node app@ohm
      mix timeless_beam_acct.watch app@ohm --print 120x40

  Four views of one moment: the groups, the processes, the jobs that ran
  in the quarter of an hour before, and the processes that ended in it.
  Under the groups and the processes is the last ten minutes of the row
  that is picked.

  | key | |
  |---|---|
  | `←` `→` | one reading back, forward: ten seconds, unless the collector was told otherwise |
  | `,` `.` | a minute |
  | `<` `>` | ten minutes |
  | `[` `]` | an hour |
  | `{` `}` | a day |
  | `home` | the first moment in the store |
  | `l`, `end` | now |
  | `t` | go to a moment, typed: `-15m`, `14:30`, `2026-09-29 14:30` |
  | `m` | go to the moment of the selected exit or job |
  | `-` `+` | a longer stretch of the timeline, a shorter: ten minutes to a week |
  | `tab`, `1` to `4` | the view |
  | `↑` `↓`, `j` `k` | the row |
  | `enter` | open the row: a group into its processes, a process or an exit into what is known of it |
  | `esc` | back out of a group |
  | `s` | sort by work, memory, queue, name |
  | `a` | applications, in place of groups |
  | `/` | show only what matches |
  | `q` | quit |

  **Now is what the collector in the node last read**, asked of the node.
  **Every other moment is read from the store** the collector writes to:
  the planes, which it says the place of. A collector that writes to
  anything else has no other moment than now.

  ## What it is told

    * the node, first, and `--cookie`, `--as`, `--collector`, as every
      task is: see `mix help timeless_beam_acct`. Without a node, now is
      the last moment in the store
    * `--metrics-url`, `--logs-url`, `--traces-url`: the planes to read,
      if they are not where the collector says it writes
    * `--token`, or `--metrics-token`, `--logs-token`, `--traces-token`:
      tokens that may read
    * `--node`, `--host`: whose series are read, of a store that has
      several nodes'
    * `--at`: the moment to begin at, and now unless told
    * `--recording`: a recording, by its id or the beginning of it
      (`mix timeless_beam_acct.recordings` lists them): its node, at its
      end, with the timeline long enough to have all of it. The planes are
      said with `--metrics-url`, `--logs-url`, and `--traces-url`
    * `--view`: `groups`, `processes`, `jobs`, or `exits`
    * `--refresh`: seconds between looks at now, 2 unless told
    * `--print`: `120x40` draws the screen once, as text, for a script or
      for where there is no terminal
  """

  use Mix.Task

  alias TimelessBeamAcct.{Remote, Watch}

  @usage "mix timeless_beam_acct.watch [NODE] [--cookie COOKIE] [--at WHEN] [--view VIEW]"

  @switches [
    cookie: :string,
    as: :string,
    collector: :string,
    metrics_url: :string,
    logs_url: :string,
    traces_url: :string,
    token: :string,
    metrics_token: :string,
    logs_token: :string,
    traces_token: :string,
    node: :string,
    host: :string,
    at: :string,
    recording: :string,
    view: :string,
    refresh: :integer,
    print: :string
  ]

  @views ~w(groups processes jobs exits)

  @impl true
  def run(args) do
    {given, rest, invalid} = OptionParser.parse(args, strict: @switches)

    case {rest, invalid} do
      {_, [{switch, _} | _]} -> Mix.raise("#{switch} is not understood.\n\n    #{@usage}")
      {[_, _ | _], _} -> Mix.raise("One node at a time.\n\n    #{@usage}")
      _ -> :ok
    end

    {reach, given} = Keyword.split(given, [:cookie, :as])

    node =
      case rest do
        [] ->
          nil

        [node] ->
          case Remote.connect(node, reach) do
            {:ok, node} -> node
            {:error, why} -> Mix.raise(why)
          end
      end

    view =
      case given[:view] do
        nil -> :groups
        view when view in @views -> String.to_atom(view)
        view -> Mix.raise("--view is #{view}: expected one of #{Enum.join(@views, ", ")}")
      end

    opts =
      given
      |> Keyword.drop([:collector, :node, :view])
      |> Keyword.merge(node: node, view: view, store_node: given[:node])
      |> then(fn opts ->
        case given[:collector] do
          nil -> opts
          name -> Keyword.put(opts, :name, String.to_atom(name))
        end
      end)

    case Watch.run(opts) do
      :ok -> :ok
      {:error, why} -> Mix.raise(why)
    end
  end
end
