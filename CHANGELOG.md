# Changelog

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
