# Releasing

What is run before a version is tagged. There is no CI, so this is what
stands in its place.

Each of these was learned by releasing without it.

## 1. The suite, on every OTP the README names

```sh
scripts/matrix.sh \
  "26.2.5.21 1.18.5-otp-26" \
  "27.3.4.18 1.18.5-otp-27" \
  "27.3.4.18 1.20.4-otp-27" \
  "28.3.2 1.19.5-otp-28" \
  "29.1.1 1.20.4-otp-29"
```

The versions are installed by mise: `mise install erlang@27.3.4.18`, and
then `mise exec erlang@27.3.4.18 -- mise install elixir@1.18.5-otp-27`,
since an Elixir is tried on the Erlang that is active when it is
installed. On a machine with GCC 16, OTP 26 is built with
`KERL_CONFIGURE_OPTIONS="--without-odbc"`.

The newest alone is not enough. What differs between them is what a
collector is built on:

| OTP | has |
|---|---|
| 26 | no trace sessions: no word of exits, no spans |
| 27 | trace sessions, and no system monitor of a session's own: no remarks |
| 28 | both, and the processes read one at a time |

0.1.0 was written on OTP 29, where a session has a system monitor. On
OTP 27 a collector told nothing did not start.

A test of what one VM lacks is skipped on every VM that has it, so such a
test guards only when the suite is run there.

## 2. Against planes that are running

```sh
ext=/path/to/libtimeless_ext.so
mkdir -p /tmp/planes
timeless-metrics-api $ext /tmp/planes/metrics.db 127.0.0.1:28428 &
timeless-logs-api    $ext /tmp/planes/logs.db    127.0.0.1:29428 &
timeless-traces-api  $ext /tmp/planes/traces.db  127.0.0.1:30428 &

TIMELESS_TEST_METRICS_URL=http://127.0.0.1:28428 \
TIMELESS_TEST_LOGS_URL=http://127.0.0.1:29428 \
TIMELESS_TEST_TRACES_URL=http://127.0.0.1:30428 \
  mix test --only planes
```

Against planes started for it, with databases that are thrown away, and
stopped afterwards by the pids they were started with.

And again against VictoriaMetrics, VictoriaLogs, and VictoriaTraces,
the single binaries of their releases, started on the same ports with
data directories that are thrown away: what the page and `watch` read is
asked as both answer, and is to be read back from both. Of Victoria's,
the tests that read by Timeless's own routes are skipped, and say so;
the rest pass, the job among them in half a minute, when VictoriaTraces
makes its trace findable. The test refuses
ports 8428, 9428, and 10428 of the machine it runs on, which are where
the planes of whoever works on that machine are.

The server the rest of the suite runs is one the suite wrote, and
answers as the suite expects. The planes answer 200 to a body they could
read half of, take a token for each signal, and store an integer that is
sent as a string as a string. None of that was known until a tick was
sent to them.

## 3. Nothing asks the planes of the machine it runs on

A collector told nothing writes to `127.0.0.1:8428`, `9428`, and `10428`.
So does `check`, which asks each for `/health`. A test that calls
`check`, `checked`, or `diagnosed` without saying where the planes are
asks the ones that are running.

```sh
grep -rnE "checked\(|check\(|diagnosed\(|diagnostics\(" test | grep -v "_url"
```

Each line it prints is of a collector that is running, whose sink was
given, or is to be looked at.

## 4. What a person will do first

In projects made for it, from the repository as it is to be tagged. An
`@github:` install takes what is pushed, so this is run after pushing
and before tagging.

**A plain application.** The installer starts nothing unless told
`--always-on`, and then only outside the tests:

```sh
mix new tried --sup && cd tried
# add {:igniter, "~> 0.6", only: [:dev, :test]} to mix.exs
mix deps.get
mix igniter.install timeless_beam_acct@github:awksedgreep/timeless_beam_acct --yes
mix run -e 'IO.inspect(TimelessBeamAcct.running?())'              # false
mix igniter.install timeless_beam_acct@github:awksedgreep/timeless_beam_acct --yes \
  --always-on --metrics-url http://127.0.0.1:1 --logs-url http://127.0.0.1:1 --traces-url http://127.0.0.1:1
mix run -e 'TimelessBeamAcct.tick(); TimelessBeamAcct.diagnostics()' # running
MIX_ENV=test mix run -e 'IO.inspect(TimelessBeamAcct.running?())'  # false
```

**A Phoenix application, with timeless_phoenix from Hex.** Made by the
newest `phx.new`; both installers, in either order; started with
`--cookie` (a node started with `--sname` and no cookie writes
`~/.erlang.cookie`) and a `PORT` of its own, the planes of section 2
given as `--metrics-url` and the rest:

- TimelessAcct is in the menu of `/dashboard`, after TimelessTraces, and
  no collector is running (`TimelessBeamAcct.status/0` is `nil`).
- With the planes stopped, the page says they do not answer, and Record
  is disabled.
- With them running, a recording of a minute is started from the page,
  ends by itself, and is in the list as having run out of time, and opens.

## 5. The rest

```sh
mix format --check-formatted
MIX_ENV=prod mix compile --force --warnings-as-errors
mix docs          # and no warning of a reference that leads nowhere
mix hex.build     # what is in the package, and nothing that should not be
```

`CHANGELOG.md` has the version and what is in it, `mix.exs` has the
version, and the tag is `v` and the version.

## Two things about the machine

Output of `mix` that is piped into `head` leaves an `erl_crash.dump`
behind: the VM ends writing to a pipe that has been closed.

The tests that start other nodes start `epmd`, and leave it running.
`epmd -kill` stops it, and refuses to if a node is registered with it.
