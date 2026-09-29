defmodule TimelessBeamAcct.OptionsTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.{Options, Sink}

  test "nothing given is a collector for the planes on this host" do
    options = Options.new!([])
    assert options.sink == {Sink.Http, []}
    assert options.host == Options.hostname()
    assert options.node == Atom.to_string(node())
    assert options.interval == 10.0
    assert options.min_age == 30.0
    assert options.trace_max_age == 3600.0
  end

  test "lengths of time are numbers or written" do
    options = Options.new!(interval: 5, min_age: "2m", trace_max_age: "1d", flush_interval: 0.5)
    assert options.interval == 5.0
    assert options.min_age == 120.0
    assert options.trace_max_age == 86_400.0
    assert options.flush_interval == 0.5
    # A process may be given series from its first sweep.
    assert Options.new!(min_age: 0).min_age == 0.0
  end

  test "a sink is named, or named with its options" do
    assert Options.new!(sink: :stdout).sink == {Sink.Stdout, []}
    assert Options.new!(sink: {:forward, to: self()}).sink == {Sink.Forward, [to: self()]}
    assert Options.new!(sink: {My.Sink, a: 1}).sink == {My.Sink, [a: 1]}
  end

  test "the planes' options may be given beside the sink, and those given with it win" do
    options =
      Options.new!(metrics_url: "http://m:1", token: "a", sink: {:http, token: "b", backlog: 10})

    assert {Sink.Http, opts} = options.sink
    assert opts[:metrics_url] == "http://m:1"
    assert opts[:token] == "b"
    assert opts[:backlog] == 10
  end

  test "a token for one plane is an option of the planes, as the token for all is" do
    options = Options.new!(token: "a", logs_token: "b", sink: {:http, traces_token: "c"})

    assert {Sink.Http, opts} = options.sink
    assert opts[:token] == "a"
    assert opts[:logs_token] == "b"
    assert opts[:traces_token] == "c"

    assert_raise ArgumentError, ~r/:metrics_token is an option of the :http sink/, fn ->
      Options.new!(sink: :stdout, metrics_token: "a")
    end
  end

  test "the planes' options given to another sink are refused" do
    assert_raise ArgumentError, ~r/:token is an option of the :http sink/, fn ->
      Options.new!(sink: :stdout, token: "a")
    end
  end

  test "a level may be changed for one way of ending" do
    options = Options.new!(exit_levels: [crashed: :warning])
    assert options.exit_levels.crashed == :warning
    assert options.exit_levels.killed == :warning
    assert options.exit_levels.normal == :info
  end

  test "spans are not kept without word of exits" do
    refute Options.new!(exits: false).traces
    assert Options.new!(exits: true).traces
  end

  test "what is wrong is refused, and named" do
    for {given, named} <- [
          {[intervl: 10], ~r/unknown option :intervl/},
          {[interval: 0], ~r/:interval must be more than no time/},
          {[interval: "soon"], ~r/:interval: "soon" is not a length of time/},
          {[vm: :yes], ~r/:vm is :yes/},
          {[max_processes: -1], ~r/:max_processes is -1/},
          {[records: :some], ~r/:records is :some/},
          {[long_gc: 0], ~r/:long_gc is 0/},
          {[long_message_queue: {10, 5}], ~r/:long_message_queue/},
          {[exit_levels: [crashed: :fatal]], ~r/:exit_levels/},
          {[exit_levels: [exploded: :error]], ~r/:exit_levels/},
          {[sink: "http"], ~r/:sink is "http"/},
          {[host: ""], ~r/:host is ""/}
        ] do
      assert_raise ArgumentError, named, fn -> Options.new!(given) end
    end
  end

  test "an option given twice is what it was last given as" do
    assert Options.new!(interval: 5, interval: 7).interval == 7.0
  end

  test "a collector's parts are named for it" do
    assert Options.name(Options.new!(name: Acct), :Collector) == Acct.Collector
    assert Options.name(TimelessBeamAcct, :Tracer) == TimelessBeamAcct.Tracer
  end
end
