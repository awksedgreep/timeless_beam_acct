# Changelog

## Unreleased

- **Recordings.** A collector told `stop_after: "1h"` ends by itself when
  its time is up, flushing what it has as a stopped collector does. Its
  timer is in the node, so it ends whether or not anyone is there to stop
  it. A day at most unless `:max_recording` (or the application's
  `:max_recording`) says more; `TimelessBeamAcct.extend/2` makes one run
  longer, up to that. A recording among the children of a supervisor is
  not started again when it ends. `status/1` says when it is to end.
- A recording writes a record when it begins and one when it ends
  (`kind` `recording`), with its id, its length, who started it, and how
  it ended: its time ran out, it was stopped, or what it ran in went
  first.
- `mix timeless_beam_acct.record NODE --for 1h`: a recording put into a
  running node; `--extend` and `--stop` while it runs. `mix
  timeless_beam_acct.recordings` lists the recordings in a logs plane,
  and `mix timeless_beam_acct.watch --recording ID` opens one.
- A page in Phoenix LiveDashboard, `TimelessBeamAcct.Dashboard.Page`,
  with `timeless_beam_acct_dashboard "/dashboard"` for the router: the
  recording running in the chosen node, with **Stop** and **+1 hour**,
  and the recordings of the logs plane. `phoenix_live_dashboard` and
  `phoenix_live_view` are optional dependencies, and the page is
  compiled only where they are.

## 0.2.0

A node in a terminal, and what a day of a node did to the planes.

- `mix timeless_beam_acct.watch`: a node in a terminal, now and at any
  moment the planes hold, with the screen and the keys of
  `timeless-acct watch`. Groups, processes, jobs, and exits; the
  timeline across the top with what went wrong marked under it; `←` `→`
  through time, `t` to a moment, `m` to the moment of an exit or a job,
  `/` to look for one. Now is asked of the collector in the node, and
  every other moment of the planes it writes to.
- `TimelessBeamAcct.reading/1`: the samples the sink was last given,
  kept in memory with the records, for whatever draws a node as it is
  now. None are kept with `history: 0`.
- `TimelessBeamAcct.snapshot/2` takes `:most`, `:group`, and `:app`: the
  first few processes of a node, or those of one group, where a node has
  too many to ask for all of.
- `TimelessBeamAcct.Http` keeps as much of an answer as it is told to,
  with `:keep`. It kept 64 KiB of any, which is enough of an answer to a
  write and not of one to a question.
- What the planes store of what a collector sends was measured over an
  hour (`bench/compression.exs`, `bench/compression_report.py`): 3.9
  bytes a sample, 43 a record, 27 a span, and 9, 45, and 40 with the
  indexes: a fourteenth of what was sent. The README has it, with how
  long each of the things written to keeps it.
- DESIGN.md has the series of an hour and not of nineteen minutes, and
  what was found of series whose samples have gone: they stay.
- A collector was left writing to planes set up as the stack sets them
  for 13.6 hours. The planes of timeless-libsql 0.8.5 compressed each
  reading's chunk alone and merged nothing: 3.3 million chunks, 2.2 GB,
  a core, and no answer to a moment (timeless-libsql #93, #94, fixed in
  0.8.6, whose planes hold the same day in 90,000 chunks and 150 MiB).
  What the collector costs was measured as the node with it and without
  it: 4 to 6% of one core, on a node ending 65 processes a second.
- `watch` asks a moment of the planes a metric at a time, by name, and
  only for the tiers its view shows: a step back through time is fifteen
  milliseconds on a store of eighty thousand series, where a pattern for
  the name cost a quarter of a second (timeless-libsql #95). It asks a
  busy plane once more before saying so, and marks what went wrong
  across the whole timeline and not as far back as one answer reaches.

## 0.1.1

What those who tried 0.1.0 first would have met, and what was found by
running it where it had not been run.

- A process that ends registered is recorded under the name it ended
  under. The VM says that a process ended and then that it gave up its
  name, and the name was taken from it before its end was accounted.
  (#3)
- A list in an exit reason is written as a list. The arguments of a
  call, `[110]`, were written as the text `~c"n"`. (#4)
- `written`, of the writer, is of the ticks the sink took. It counted
  those that failed as well. (#5)
- `check` says the sink once, and says why one cannot be made as it was
  written, without the backslashes of a string written out. (#6)
- A label that is not text is made text, as a record's fields are. One
  such name cost a tick all of its samples in the stores in the node.
  (#7)
- OTP 26 is the oldest VM a collector is said to run on. OTP 25 could
  not be run here, and was in the README without having been. What a
  collector does on a VM that cannot be asked for one key of a
  dictionary is tested on one that can. (#9)
- `mix igniter.install --sink timeless` was run against an application
  made by `mix phx.new` with `timeless_phoenix` 2.0.3: it starts, and
  what the collector records is read back from the three stores. (#8)
- Where the metrics store has another name than the one written to, the
  error names the store that is running and says what to write.
- With the stores in the node, the stores are called from one process
  that is kept, and not from one for each call. A collector accounts
  for every process that ends, and recorded three of its own at every
  tick.
- A collector among the children of a supervisor does not start where
  the configuration says `start: false`, and the installer says so in
  `test.exs` for every sink. With the stores in the node a collector is
  a child, and ran with the application's tests.
- `docs/RELEASING.md`, which is what is run before a version is tagged,
  and `scripts/matrix.sh`, which runs the suite on each OTP that is
  named.

## 0.1.0

The first version.

- What sar would record of a node (`beam_vm_*`), of its tables
  (`beam_ets_*`), and of its connections to other nodes (`beam_dist_*`).
- Series for every application (`beam_app_*`), for every group of
  processes that are the same thing (`beam_group_*`), and for every
  process that has a name or is large (`beam_proc_*`).
- An accounting record for every process that ends, from the VM's own
  word of it, through a trace session of the collector's own (OTP 27).
- A span for every process that ends, in the trace of the job it was
  part of.
- What the VM remarks on: long garbage collections, long queues, large
  heaps, busy ports (OTP 28, which is when a trace session was given a
  system monitor of its own).
- Sinks: the Timeless planes over HTTP, the Timeless stores in the node,
  the terminal, and a process.
- For planes that require one, a token for each: `:metrics_token`,
  `:logs_token`, and `:traces_token`. A token is issued for one signal,
  and the plane of another answers it with 401.
- A record the logs plane could not read is a failed write, though the
  plane answers 200 to it: it stores the lines it can read and counts
  those it cannot.
- `check` says what each plane says it is, and says so as a failure when
  a plane is reached at the URL of another.
- `TimelessBeamAcct.top/1`, `exits/1`, `trees/1`, and `check/1`, from a
  shell on the node.
- `TimelessBeamAcct.Remote` and the `mix timeless_beam_acct.*` tasks,
  which put a collector into a node that is already running, look at it
  from a terminal, and take it out again.
- `mix igniter.install timeless_beam_acct`, which configures a collector
  to start with an application and to stay off while its tests run.
  Igniter is an optional dependency, for this and nothing else.
- `TimelessBeamAcct.diagnostics/1` and `mix timeless_beam_acct.diagnostics`,
  which print what a report of a problem should have in it.

Changed before it was released, from what was first written:

- An application, a group, or a table that has emptied is reported as
  nothing for as long as it keeps its place, and a peer that has gone is
  reported once more, as nothing. Its last sample said before that it
  was as full as it last was, and a reader that looks back five minutes
  for the last sample read that for five minutes. (#2)
- Two nodes on one host are told apart by `node`, and not by telling
  each collector a `:host` of its own. (#1)

Run on OTP 26, 27, 28, and 29. On OTP 26, which has no trace sessions,
a collector runs without word of exits. Written to the planes (0.8.5),
and to `timeless_metrics` 6.6.7, `timeless_logs` 1.11.2, and
`timeless_traces` 1.11.1 in the node, and read back from each.
`test/planes_test.exs` is what writes to planes that are running, and
is run by `mix test --only planes`.
