# Design

Why timeless_beam_acct is shaped the way it is. The README says what it
does; this says what was decided, and what the decision cost.

It is the counterpart, for a node, of
[timeless-acct](https://github.com/awksedgreep/timeless-acct) for a host,
and where a decision was made there it is followed here. What is written
below is mostly where a node is not a host.

## The goal

Put a process on a Timeless canvas, watch it, and drag the timeline back
to see what it was doing last Tuesday. For every process of the node, and
for the node itself, with nothing unaccounted for.

## 1. The canvas decides the shape of a metric

A canvas element names a line most easily by **host, metric name, and one
more label**, and it draws **the last value in each time bucket**.

So, as on a host:

**Every metric is a gauge, with the rate already taken.**
`beam_proc_reductions` is the one cumulative figure kept, because "how
much has this process done in its life" is an accounting question in its
own right.

**Names are flat, and a label is what varies.** Every metric differs from
its siblings by one label at most: `scheduler`, `table`, `peer`, `app`,
`group`, or `proc`.

And two things that a host did not have to decide.

**Every name begins `beam_`.** A node runs on a host, and timeless-acct
may be recording the host under the same `host`. Both have processes, and
both have a collector with figures of its own. `proc_*` and `acct_*` are
the host's.

**`host` is the host, and `node` is beside it.** A node's lines belong
with the lines of the host it runs on, which is what an element's `host`
chooses by, and the host's element takes its colour from the records
logged under its name, the node's among them.

Two nodes on one host have series that differ only by `node`. An element
chooses by it as it does by any label: every field of an element that
does not configure it is a label it chooses by, and choosing a series
from the list writes all of that series' labels. One more label is what
a second node costs.

The first version of this document said that an element could not choose
by `node` as well as by `app`, and that such a host's collectors should
each be told a `:host` of their own. That would have taken the node from
beside its host, which is the reason `host` is the host: its samples,
its records, and its spans would all have been under a name that is no
host's, and the host's element would not have turned red for them.

### Work is counted in reductions

A host counts CPU time for each process. A node does not: it counts
reductions, which are about function calls, and gives each process so
many before the next has its turn. So what a process did is in reductions
a second, and as a share of all the reductions of the node
(`_work_pct`), which is the figure that means the same on any hardware.

`beam_vm_cpu_pct` is the CPU time of the node itself, from the operating
system, for setting a node beside its host.

## 2. "Every process" decides the tiers

On a host, most processes live for milliseconds, and a series for each
would be millions of dead series a day. That is as true of a node, and
more: a node that answers requests starts a process for each.

But a node differs from a host at the other end too. A host has a few
hundred processes that live long, and timeless-acct gives each of them
series once it is thirty seconds old. A node may have a hundred thousand:
one for each connection. Age alone cannot decide who gets series.

| tier | what | how many |
|---|---|---|
| `beam_app_*` | one application | the applications that are running |
| `beam_group_*` | everything that is the same thing, together | `:max_groups`, and `other` |
| `beam_proc_*` | one process | `:max_processes`: those with a name, then those that are large |
| accounting record | a process that ended | none: it is a row, not a series |

### Who gets series of their own

A process that has lived for `:min_age`, and either:

- **is registered under a name**, which is a process someone means to be
  able to find, and will look for on a canvas by that name; or
- **is notable**: it holds sixteen megabytes, or has a thousand messages
  waiting, or does a hundredth of what the node does. These are the
  processes an incident is about, and they have no name to be found by
  beforehand.

**A process that is given series keeps them until it ends.** If places
were given afresh at each sweep to whoever was largest, a process near
the edge would be a line on one reading and absent from the next, and
every process that was ever briefly large would leave a series of a few
points behind.

The same is done for groups and for tables
(`TimelessBeamAcct.Admission`): a name that has a place keeps it, and
keeps it for a few readings while it is absent, since a pool between two
jobs has no processes and is the same pool when it has them again.

### How many series that is, over time

`:max_processes` is how many processes have series at once. It is not
how many ever have. When a process that has series ends, its place goes
to the next, and its series stay where they were written: `proc` has the
pid in it, and no process has that pid again. So the series of a node
are those of the tiers that are bounded, and five more for every process
that has ever been given a place.

Measured at the end of an hour of `bench/compression.exs`, which is a
node of some five hundred processes with 25 requests a second:

| | series |
|---|---:|
| of processes | 3,260 |
| of groups | 1,332 |
| of tables, applications, the node, and the collector | 407 |

652 processes had had series and 146 had them then. That is 42 new
series a minute: ten thousand in an afternoon spent looking for what is
wrong, sixty thousand in a day, and a million in sixteen days.

The most it could be is two hundred places given up every forty seconds,
which is two million series a day. Nothing a node does is like that, and
nothing in the collector prevents it.

**This is left as it is**, because of what a collector is for. It is put
into a node when something is wrong and taken out when it has been
found, and over hours the series of processes are a few thousand. The
planes have been run with a million. What is bounded, the groups and the
applications and the tables, is what is for a collector that is left
running.

Two things would bound it, and neither is done. They are written down so
that they need not be thought of again.

**A process without a name could wait longer than one with.** Nearly all
of the series that were dead in that run were of two kinds of job that
take thirty to ninety seconds. They had no name. They were notable for
doing a hundredth of what the node did, which on a node that is doing
little is not much to do, and each was given five series, wrote a few
samples to them, and ended. That is what the tiers are there to avoid: a
series for a process that was hardly there. A name is what someone will
look for, and thirty seconds is long enough to wait for one. What has no
name matters if it stays, and could be made to wait five minutes.

The threshold is a share, and that is what lets a job through on a quiet
node. An amount would not: so many reductions a second, whatever the
node is doing.

**New places could be counted by the hour.** So many processes given
series in an hour and no more, with a figure for those that were turned
away. What grows without limit would then grow at a rate that is known,
and the figure would say when the rate was reached.

What can be done without either, by whoever leaves a collector running:

| to | tell it |
|---|---|
| give series only to what stays | `min_age: "5m"` |
| leave out what is notable only for its work | `notable_work: 100` |
| give series to no process | `max_processes: 0` |

### What is kept of them

A collector keeps nothing. How long a sample is kept, and what is made
of it when it is old, is said to the planes or the stores and not to the
collector, and the README has what each says when nothing is said to it.

What was asked is whether a store that a collector writes to grows to a
size and stays there. It was tried: three metrics planes of
timeless-libsql 0.8.5 told to keep samples for ninety seconds, one with
no rollups, one keeping a rollup of a minute for five minutes, and one
keeping it for thirty days. Each was given six thousand series for a
minute, a thousand new ones every ten seconds, and after that only
fifty that stay.

| | after three minutes | after nine |
|---|---|---|
| samples of the six thousand | gone | gone |
| their rollups, kept five minutes | there | gone |
| their rollups, kept thirty days | there | there |
| the six thousand series | there | there |

Samples go when they are old and rollups go when they are old. Series do
not go. With no rollups and no sample left of them, the six thousand
were still counted and still listed, and were 255 bytes each in the
file. Nothing in the planes removes a series.

So a store that a collector is left writing to comes to a week of
samples, records, and spans, and then grows by its series alone: by the
bench node's count, sixty thousand a day and 15 MiB. A rollup kept for
good is a row for every series for every thirty days it was written to,
which is one row for nearly all of them.

That is small beside a week of samples, which for that node is 1.3 GiB
with the index of their chunks.
It is not nothing: the planes read at most a million series to answer
what series there are (`TIMELESS_METRICS_PROMQL_MAX_CATALOG_SERIES`),
and that is the sixteen days above.

### A name that has a place is reported at every reading

A reader takes the last sample of a series as its value until a newer
one comes. PromQL looks back five minutes for it. Nothing marks a series
as over, so the last sample of a pool that has emptied would go on
saying, for five minutes, that the pool is as full as it last was.

A group, an application, or a table that has a place is therefore
reported at every reading, and as nothing while it has nothing. "This
pool has no processes" is a reading, and a true one. When the name has
been absent long enough to lose its place, the last samples of its
series are of nothing, and are true whatever a reader's window. A peer
that has gone is reported once more, as nothing, for the same reason.

It follows that a name does not move into `other` while it is there to
be reported. What is in `other` is what arrived when there was no room,
and what came back after losing its place.

**A process is not given a last sample of nothing.** Its series is of
one process, and ends when the process does. A sum over the processes of
a group is therefore right only if the reader's window is about the
sweep interval, which is what `beam_acct_sweep_interval_seconds` is
there to tell it, and what the README says to ask with. It is also what
timeless-acct does, and the two are read by the same readers.

A last sample of nothing would make such a sum right under any window,
and would leave a count wrong: a series whose last sample is nothing is
still a series. What makes both right is a sample that says the series
has ended, which the planes would have to understand.

### What the totals hold, and what they do not

The totals of a group and of an application are over every living
process, whatever its age. A process that was not there at the last
sweep was started since, so all it has used belongs to this interval.

On a host, what a process used between its last sample and its exit is
in its exit record, and the totals are complete. Here it is not known
(see [what the VM does not say](#what-the-vm-does-not-say)), and the
totals lack it, along with everything done by processes that no sweep
saw.

What can be said is how much is lacking. `beam_vm_reductions_per_sec` is
the node's own count, and misses nothing.
`beam_acct_reductions_accounted_pct` is the sum of what the sweep found
processes for, as a share of it. On a node whose work is done by servers
it is near a hundred, and on one whose work is done by processes that
live for a millisecond it is not, and the figure says which this is.

## What a process is

On a host a process has a command name, given by the kernel. A process of
a node has a pid and nothing else that the VM requires of it. What it is
for is learned from the first of these that applies:

1. **the name it is registered under**;
2. **its label**, which it gave itself (`:proc_lib.set_label/1`);
3. **what it was started with**, as `:proc_lib` and `Task` record it:
   the callback module of a server, the function of a task;
4. **the function it was spawned with**.

That is its **group**, which is to a node what a command name is to a
host, and an application is what a unit is: the name that outlives a
restart.

### An instance is named for what it is an instance of

A pool registers its workers as `worker_1` to `worker_50`, and a registry
its partitions as `PIDPartition0` to `PIDPartition21`. Under those names
each would be a line of its own, and the pool would not have one. A
trailing number is removed, and the instances are added together.

This is the decision timeless-acct makes about the scopes a desktop
starts its applications in, for the same reason, and it has the same
cost: two instances cannot be told apart in this tier. They can in
`beam_proc_*`, where a process is under its full name.

### Learned from what it was started with

Asking a process what it is (`Process.info/2`) can be done only while it
lives, and most are gone before a sweep comes round. But the VM reports,
with the start of a process, the module, function, and arguments it was
started with. For a server those are the arguments of `:proc_lib`, among
which is the callback module, and the name it will register. For a task
that is not replied to, they include its function.

So what a process is, is worked out from what it was started with, the
way `:proc_lib` itself works it out, and the process is asked only if it
lives to a sweep: once when a sweep first finds it, and once more when it
is old enough for series, by which time it has said what it has to say of
itself.

The arguments are looked at and let go. They are whatever the process was
given to work on, and may be large.

### The moment it took up its work

A task that will be replied to is started with nothing, and is sent what
to do afterwards. The first version called every such task by the
function that waits to be sent one, which is most of the tasks of most
applications, and the trees it drew were of processes all of one name.

On a host, timeless-acct learns what a process is running at the moment
it calls exec. The counterpart here is a call too. When a task takes up
what it was sent, it calls a function that returns what it is about to
run, and the VM will tell of that call, and of its result, to whoever
asks. Likewise the call by which a process gives itself a label.

Two things keep this from costing what tracing calls is known to cost.

- **The VM marks the two functions**, and tells of a call by reaching the
  mark. A call to any other function is not looked at. Five million calls
  of an unmarked function took the same time with every process being
  listened to as with none.
- **A call is told of without its arguments.** What a task was given to
  do comes as the result of the call, which is a module, a function, and
  an arity. What it was given to work on is never sent for.

A module that is loaded afresh has no marks. They are made again each
minute.

## 3. "Nothing unaccounted for" decides the source

Sampling sees a process only if it is alive at a sweep. There are five
ways to learn of the rest:

| source | sees | costs | chosen |
|---|---|---|---|
| a monitor on every process | every exit, and its reason | a monitor has to be set, by asking for the list of processes, which is sampling again | no |
| the tracer of the node (`:erlang.trace/3`) | every start and exit | there is one, and whoever asks for it last has it | no |
| a trace session (`:trace`, OTP 27) | every start and exit | a message for each | **yes** |
| a tracer written as native code | the same, and what the process had used | a shared library for every platform | not yet |
| sampling alone | what lives to a sweep | nothing more | where there is no other |

Until OTP 27 a node had one tracer. A collector that traced every process
would have taken `:dbg` and `:recon` away from whoever was using them to
find out what was wrong, and lost its own exits to the next person who
did. A trace session has its own tracer and its own settings, and any
number of them hear of the same process.

Since OTP 28 a session also has its own system monitor
(`:trace.system/3`), so what the VM remarks on is heard without taking
`:erlang.system_monitor/2` from an application that has set it. On
OTP 27 a session has none. The node's one system monitor is not taken
in its place, for the reason the node's one tracer is not: there the
collector accounts for every exit and records no remarks, and says so.

On an older VM there is no tracer, and the collector says so. What is
made of the VM's word of each exit is not made there: a process noticed
gone has a record, and no span.

### What the VM does not say

The kernel's record of an exit has what the process used: its CPU time,
its peak memory, its I/O. The VM's word of an exit has the pid and the
reason. By the time the word arrives there is no process to ask.

So the **times** of a record are the VM's, and are exact: when it
started, when it ended, to the microsecond. Its **figures** are those of
the last sweep that saw the process alive. They are a floor, the record
says how old they are (`figures_age_seconds`), and a process that no
sweep saw has a record with no figures in it rather than with zeros.

A tracer can be native code that runs in the process being traced, and
such a tracer could read what the process had used as it ended. That is
the way to the figures. It is also a shared library to be built for every
platform a node runs on, in a package that today has no dependencies and
can be sent to a running node as it is.

### When the VM says nothing

A process that was there at one sweep and gone at the next gets a record
marked `source: "sampled"`, with the figures of the last sweep that saw
it and a status of `unknown`.

With the VM reporting, a process found gone waits one sweep for word of
its end, in case the message is still in flight. If none comes, it was
lost, and the sampled record is written instead. Every process that was
ever swept gets exactly one record, one way or the other.

### When there is too much to hear

A node can start processes faster than one process can hear of them, and
a tracer that falls behind holds in its queue everything it has not yet
read: the arguments and the reasons, whole.

If more than `:trace_max_queue` messages are waiting, the tracer stops
listening, works through what it has, and listens again after a few
seconds. It says so (`beam_acct_trace_listening`,
`beam_acct_trace_suspensions`). Processes that started in between and
are still running are found by the next sweep, and those that ended are
noticed gone.

Measured: the tracer heard of 200,000 processes a second in full, for an
eighth of one scheduler. A node starting five million a second started as
many with a collector in it as without, and the collector heard of the
first few tens of thousands.

The tracer has the priority of any other process. It is there to watch
the node, and not to be served before it.

### The collector reads the tracer's table, and asks it nothing

What the tracer keeps of what it hears goes into a table, and the
collector takes it from the table at each tick. A question to the tracer
would wait its turn behind every message from the VM, and the collector
asks at the moment the tracer has most to read.

It is taken a lot at a time, fifty thousand to a lot, so that a node that
started a million processes since the last tick does not have them all
in the collector's memory at once.

## How a process ended

A reason is any term, and may hold whatever the process held: a server
that crashes ends with its last message and its state. So a reason is
read once, where it arrives, into the few words kept of it, and let go.

| a process that | is | its status |
|---|---|---|
| ended, or was told to shut down | normal | `normal`, `shutdown` |
| ended for a reason of its own | abnormal | the reason's first word: `timeout`, `noproc` |
| was killed | killed | `killed` |
| raised, and nothing caught it | crashed | what it raised: `RuntimeError`, `badmatch` |
| was noticed gone | unknown | `unknown` |

**What tells a crash from a reason of the process's own is the stack.**
An error carries the place it was raised, and `exit/1` does not.

**The status is the first word of the reason**, so that there are few
enough of them for every exit of one kind to be found by it. The rest of
the reason is metadata, cut to two hundred characters.

**A call from another node ends with its answer.** `:erpc` hands back
what a call returned by ending the process that made it, with the answer
as the reason. The first version recorded every such call as a process
that had failed, with a status of `other`. It is accounted as the call
ended: normally, if it returned.

### The level is a judgement about the host

A canvas host element turns red when the host logged an error in the last
minute, and amber for a warning. So the level of a record decides the
colour of the host, and is chosen for that:

| ending | level | why |
|---|---|---|
| normal, shutdown | info | |
| a reason of its own | notice | it is how a process says what happened to it |
| killed | warning | someone insisted, or a supervisor ran out of patience |
| crashed | error | a program on this node is defective |

A node is built to let a process crash and start another, and a node that
does so is working. The crash is a defect all the same, and the one
someone will want to have been told of. Where that is not wanted,
`:exit_levels` says otherwise.

## Traces

A process has a start, a duration, and a parent, which is what a span is.
What it does not have is a trace. The tree of processes has one root,
`init`, and a trace of everything since the node started says nothing.

### A trace is a job

On a host a job is a process group, which a shell makes for each command
it is given. A node has no process groups. What it has is supervisors:
a process that answers a request, runs a task, or handles a message from
a queue is started by one.

So a job is a process that a supervisor started, and everything that
process started, and so on down. A supervisor is known by what it was
started with; `:trace_roots` names any other module whose processes
start jobs and are not part of them, such as an acceptor written by
hand.

### Except for servers

A job ends. A server that a supervisor started is the root of a trace
too, and everything it starts in a month would be one trace. So a
process joins the trace of the process that started it only if it
started within an hour of that trace. Past that, what a server starts is
the root of a trace of its own.

### On behalf of

A task is started by whoever asked for it, or by a task supervisor on
behalf of whoever asked. Either way it is part of the job of the process
that asked, and that is whose span it is a child of. Who asked is among
what a task is started with.

Its application is another matter. A process runs in the application of
the process that started it, which for a task under a supervisor is the
supervisor's.

### Ids are decided at the start

A child ends before its parent. Its span is written first, and must
already carry the trace id its parent's span will carry when the parent
ends, minutes later. So a process's place is decided when it is first
heard of, from what is known then, and does not change.

And the ids are made, not drawn: a hash of the node's incarnation and
the pid. The incarnation is made when a collector first starts in a node
and kept for as long as the node runs, so a collector that is restarted
gives a running process the id it gave it before.

The hash is MD5, which the VM has in itself. Nothing is kept secret by
it, and a collector that needed `:crypto` could not be sent to a node
that was built without it.

### Everything heard of is laid out first

In one tick the collector hears of starts and of ends, and a child is
heard of before its parent as often as after. So what started is laid
out, and then each is given its place, with the process that started it
given its place first if it has none. Only then is what ended accounted:
a process is described by its parent, which may have ended in the same
tick.

### The same figures, to two readers

A span is made from the accounting record of the same process, not
beside it, so the two cannot disagree. A record is found by what
happened: everything that was killed. A span is found by where it
happened: everything this request started, and in what order.

## Only so much

A collector is in the node it watches, and what it uses the node does
not have. Each thing that can grow has a limit, and a figure that says
the limit was reached.

| what | is limited by | and then | said by |
|---|---|---|---|
| what waits to be heard | `:trace_max_queue` | the tracer stops listening for a while | `beam_acct_trace_suspensions` |
| records of one tick | `:max_records`, of each kind | what ended is counted and not described | `beam_acct_records_dropped` |
| remarks of one tick | `:max_anomalies` | they are counted | `beam_acct_remarks_dropped` |
| the time a sweep takes | `:sweep_budget` | sweeps are further apart | `beam_acct_sweep_interval_seconds` |
| series | `:max_processes`, `:max_groups`, `:max_tables` | the rest are together, as `other` | `beam_acct_processes_reported` |
| ticks waiting to be written | 32 | a tick is let go | `beam_acct_ticks_dropped` |
| what waits for a plane | `:backlog` | the oldest is dropped | the writer's error |
| what is kept in memory to look at | `:history` | the oldest makes way | |

### A record of each kind

`:max_records` of the processes that ended as they were meant to are
described from one tick, and as many again of those that did not. The
second is its own limit so that a node ending ten thousand requests a
second still has a record of the eleven that failed.

Describing a process is most of what accounting for it costs: twelve
microseconds, against six to count it. So those past the limit are not
described and then dropped. They are counted.

## Where it goes

### One encoder

Metrics leave as Prometheus exposition text, records as NDJSON, and spans
as OTLP/JSON, which are what the planes accept. The sink that writes to
the stores in the node takes its labels, its metadata, and its resource
from the same functions, so a record is the same record whichever way it
arrived.

### The writer is a process of its own

A plane that is unreachable takes as long to say so as it is given. On a
host, timeless-acct waits for it, with a timeout shorter than its
interval. Here the wait is in another process, so that it delays the next
write and not the next reading: a reading that is late is a rate over the
wrong interval.

### One thing differs from timeless-acct on purpose

There, the first failure ends the sending of what waits, whichever plane
it came from. Here, a failure ends it for that plane only. If the logs
plane is down the samples must still arrive.

And a plane that says the body itself is what is wrong (400, 413, 415,
422) would say so again. Such a body is let go, and counted, rather than
holding up everything behind it for the hour it would take to be dropped.

## No dependencies

A collector needs JSON, HTTP, and a hash. Elixir has the first since
1.18. The second is what `:gen_tcp` and the VM's own reading of HTTP
make short work of, for a client that posts a body and reads a status.
The third is MD5.

What that buys is that a collector is its own modules and nothing else,
and so can be sent to a node that is already running.

Igniter is a dependency, and an optional one: it is what
`mix igniter.install` is written with, it is not among what an
application is built with unless the application has it already, and
the installer is not among the modules that are sent to a node.

### The installer writes configuration, and not a child

The other Timeless packages are put among the children of the
application's supervisor. A collector is put in the configuration
instead, with `start: true`, and with `start: false` for the tests.

A child of the supervisor is started wherever the application is, which
includes its tests. A collector there would hear of every process a test
suite starts, and send what it heard to the planes on the machine of
whoever ran the tests.

### Into a running node

The node that needs accounting for is the one that is misbehaving now,
and it was built last month without a collector in it. On a host this
does not arise: timeless-acct is started, and accounts for what was
already running.

So the collector's modules are sent to the node and loaded, and a
collector is started there. It belongs to no supervisor of the node's,
since the node has none that expects it. It is held by a process of its
own, which is not linked to whoever attached it: the node that attached
it can go, and the collector stays until it is detached or the node ends.

Detaching takes the modules out again, if attaching put them in, and if
no other collector that was attached is still running. The first version
took them out whenever an attempt to attach failed, including the
attempt to attach a second collector to a node that had one, whose
modules those were.

## Ticks land on round times

A reading is taken at each multiple of the interval on the wall clock,
and stamped with that time. Two nodes sample at the same moments, a node
samples at the moments its host does, and a graph bucket never splits an
interval. Rates use the monotonic clock for the length of the interval.

## What is not here yet

Ordered by how much each would add.

1. **What a process had used when it ended**, from a tracer written as
   native code. It would make the records' figures exact and the totals
   complete, and it is the one thing here that cannot be done by a
   collector that is only its own modules.
2. **A sample that says a series has ended**, for the processes that
   have series. It needs the planes to understand one. Until then a
   reader has to be told the window to ask with.
3. **A limit to the series of processes, over time.** There is one to
   how many have series at once, and none to how many ever have. See
   [how many series that is, over time](#how-many-series-that-is-over-time),
   which has the two things that would bound it and why neither is done.
4. **Reading the stores.** `top`, `exits`, and `trees` read what the
   collector has in memory, which is the last few minutes. A moment last
   Tuesday is in the stores, and is looked at on a canvas.
5. **Memory a process holds outside its heap.** A large binary is held by
   reference, and is counted once for the node and not against the
   processes that hold it. Asking a process for its binaries costs a walk
   of its heap, so it would be asked of the processes that have series.
6. **Ports**: sockets and files, each with what it has read and written,
   and the process that owns it.
7. **A smaller table.** A row of the table of processes is 470 bytes,
   mostly the names a process goes by, written out in every row. They
   could be written once.
8. **Jobs longer than an hour.** What a job starts after its first hour
   is a trace of its own.
