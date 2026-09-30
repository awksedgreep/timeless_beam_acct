# A node to watch: the node of bench/varied_node.exs, under a name, with
# a collector in it that writes to planes that were started for it.
#
#     TIMELESS_TEST_METRICS_URL=http://127.0.0.1:28428 \
#     TIMELESS_TEST_LOGS_URL=http://127.0.0.1:29428 \
#     TIMELESS_TEST_TRACES_URL=http://127.0.0.1:30428 \
#       elixir --sname varied --cookie varied -S mix run --no-halt bench/watch_node.exs
#
# and then, from another terminal:
#
#     mix timeless_beam_acct.watch varied@$(hostname -s) --cookie varied
#
# The screen in the README is of it. The planes are those of
# `mix test --only planes`: their own ports, and databases that are
# thrown away. Without them the collector writes to nothing, and what is
# watched is now.

urls =
  for {key, variable, not_on} <- [
        {:metrics_url, "TIMELESS_TEST_METRICS_URL", 8428},
        {:logs_url, "TIMELESS_TEST_LOGS_URL", 9428},
        {:traces_url, "TIMELESS_TEST_TRACES_URL", 10428}
      ],
      url = System.get_env(variable) do
    if URI.parse(url).port == not_on,
      do: raise("#{variable} is #{url}: that is where the planes of this machine are")

    {key, url}
  end

unless Node.alive?() do
  raise "this node has no name: start it with --sname, so that it can be watched"
end

System.put_env("VARIED_ALONE", "0")
Code.require_file("varied_node.exs", __DIR__)
Varied.Apps.start(seed: 1)
Process.sleep(1_000)

sink =
  case urls do
    [_, _, _] ->
      [sink: :http] ++ urls

    # To a process that takes each tick and keeps none of them.
    [] ->
      [
        sink:
          {:forward,
           to:
             spawn(fn -> Stream.repeatedly(fn -> receive(do: (_ -> :ok)) end) |> Stream.run() end)}
      ]

    _ ->
      raise "one plane was named and not all three: where are the others?"
  end

{:ok, _} = TimelessBeamAcct.start_link(sink)

IO.puts(
  "#{node()} is there to be watched: mix timeless_beam_acct.watch #{node()} --cookie #{Node.get_cookie()}"
)

Process.sleep(:infinity)
