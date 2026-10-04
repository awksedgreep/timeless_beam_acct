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

    # A recording is the last child, and ends first. When its time runs
    # out it ends normally, and its supervisor, this, with it.
    case options.stop_after do
      nil ->
        Supervisor.init([{Writer, options}, collection], strategy: :one_for_one)

      _length ->
        Supervisor.init([{Writer, options}, collection, {Recording, options}],
          strategy: :one_for_one,
          auto_shutdown: :any_significant
        )
    end
  end
end
