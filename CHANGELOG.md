# Changelog

## Unreleased

- An application, a group, or a table that has emptied is reported as
  nothing for as long as it keeps its place, and a peer that has gone is
  reported once more, as nothing. Its last sample said before that it
  was as full as it last was, and a reader that looks back five minutes
  for the last sample read that for five minutes. (#2)
- Once there has been an `other`, there is one at every reading.
- README: what window a PromQL reader should ask with, and where the
  interval it follows is reported. (#2)
- README and DESIGN.md: two nodes on one host are told apart by `node`,
  and not by telling each collector a `:host` of its own. (#1)
- `top`, by age: the processes that were running before the collector
  come before those it heard the start of.

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
  heaps, busy ports.
- Sinks: the Timeless planes over HTTP, the Timeless stores in the node,
  the terminal, and a process.
- `TimelessBeamAcct.top/1`, `exits/1`, `trees/1`, and `check/1`, from a
  shell on the node.
- `TimelessBeamAcct.Remote` and the `mix timeless_beam_acct.*` tasks,
  which put a collector into a node that is already running, look at it
  from a terminal, and take it out again.
