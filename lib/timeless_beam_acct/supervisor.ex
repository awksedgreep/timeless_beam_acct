defmodule TimelessBeamAcct.Supervisor do
  @moduledoc """
  A collector: the writer, and beside it the tracer and the collection
  loop.

  The loop reads what the tracer heard from the tracer's own table, so if
  the tracer ends the loop is started again with it, and what each knew of
  the running processes is learned again from a sweep. The writer is apart
  from both: if it ends, what it had waiting is lost, and nothing that is
  known of the node is.
  """

  use Supervisor

  alias TimelessBeamAcct.{Collector, Options, Recording, Tracer, Writer}

  @spec start_link(Options.t()) :: Supervisor.on_start()
  def start_link(%Options{} = options) do
    Supervisor.start_link(__MODULE__, options, name: Options.name(options, :Supervisor))
  end

  @impl true
  def init(%Options{} = options) do
    flags =
      if options.stop_after,
        do: [strategy: :one_for_one, auto_shutdown: :any_significant],
        else: [strategy: :one_for_one]

    # A recording that is to begin later begins as one that waits, which
    # starts the rest when it is time.
    children =
      if options.start_at && options.start_at > TimelessBeamAcct.Clock.now(),
        do: [{Recording.Waiting, options}],
        else: children(options)

    Supervisor.init(children, flags)
  end

  @doc """
  What a collector is made of: the writer, and beside it the tracer and
  the collection loop; and, if it is a recording, what ends it, which is
  the last child and ends first.
  """
  @spec children(Options.t()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(%Options{} = options) do
    collection = %{
      id: :collection,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [{Tracer, options}, {Collector, options}],
           [strategy: :rest_for_one, name: Options.name(options, :Collection)]
         ]}
    }

    [{Writer, options}, collection] ++
      if options.stop_after, do: [{Recording, options}], else: []
  end
end
