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

A canvas element selects a series by **host, metric name, and at most one
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
chooses by. The cost is that two nodes on one host have series that
differ only by `node`, which an element cannot choose by as well as by
`app`. Such a host's collectors are each told a `:host` of their own.

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

A session also has its own system monitor, so what the VM remarks on is
heard without taking `:erlang.system_monitor/2` from an application that
has set it.

On an older VM there is no tracer, and the collector says so.

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
2. **Reading the stores.** `top`, `exits`, and `trees` read what the
   collector has in memory, which is the last few minutes. A moment last
   Tuesday is in the stores, and is looked at on a canvas.
3. **Memory a process holds outside its heap.** A large binary is held by
   reference, and is counted once for the node and not against the
   processes that hold it. Asking a process for its binaries costs a walk
   of its heap, so it would be asked of the processes that have series.
4. **Ports**: sockets and files, each with what it has read and written,
   and the process that owns it.
5. **A smaller table.** A row of the table of processes is 470 bytes,
   mostly the names a process goes by, written out in every row. They
   could be written once.
6. **Jobs longer than an hour.** What a job starts after its first hour
   is a trace of its own.
