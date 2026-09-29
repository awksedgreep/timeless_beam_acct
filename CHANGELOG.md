# Changelog

## Unreleased

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
