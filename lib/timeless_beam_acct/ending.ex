defmodule TimelessBeamAcct.Ending do
  @moduledoc """
  How a process ended, from the reason it ended with.

  A reason is any term, and may hold whatever the process held: a server
  that crashes ends with its last message and its state. So a reason is
  read once, where it arrives, into the few words kept of it, and let go.

  | a process that | is | its status |
  |---|---|---|
  | ended, or was told to shut down | `:normal` | `normal`, `shutdown` |
  | ended for a reason of its own | `:abnormal` | the reason's first word: `timeout`, `noproc` |
  | was killed | `:killed` | `killed` |
  | raised, and nothing caught it | `:crashed` | what it raised: `RuntimeError`, `badmatch` |
  | was noticed gone | `:unknown` | `unknown` |

  What tells a crash from a reason of the process's own is the stack: an
  error carries the place it was raised, and `exit/1` does not.

  A call from another node (`:erpc`, `:rpc`) is a process that ends with
  the answer as its reason. It is accounted as the call ended: normally,
  if it returned.
  """

  @type class :: :normal | :abnormal | :killed | :crashed | :unknown

  @type t :: %__MODULE__{
          status: String.t(),
          class: class(),
          reason: String.t() | nil,
          at: String.t() | nil
        }

  @enforce_keys [:status, :class]
  defstruct [:status, :class, :reason, :at]

  @reason_length 200
  @status_length 64

  @doc "The ending a reason says."
  @spec of(term()) :: t()
  def of(:normal), do: %__MODULE__{status: "normal", class: :normal}
  def of(:shutdown), do: %__MODULE__{status: "shutdown", class: :normal}

  def of({:shutdown, detail}),
    do: %__MODULE__{status: "shutdown", class: :normal, reason: written({:shutdown, detail})}

  def of(:killed), do: %__MODULE__{status: "killed", class: :killed}

  # A call from another node is a process that ends with its answer as its
  # reason: that is how `:erpc` hands the answer back. It ended as the
  # call did.
  def of({asked, :return, _answer}) when is_reference(asked),
    do: %__MODULE__{status: "normal", class: :normal}

  def of({asked, :exit, reason}) when is_reference(asked), do: of(reason)

  def of({asked, :error, reason, stack}) when is_reference(asked) and is_list(stack),
    do: of({reason, stack})

  def of({asked, :throw, thrown}) when is_reference(asked),
    do: %__MODULE__{status: "nocatch", class: :abnormal, reason: written({:nocatch, thrown})}

  def of({reason, [frame | _] = stack} = whole) do
    if frame?(frame) do
      %__MODULE__{
        status: status(reason),
        class: :crashed,
        reason: raised(reason),
        at: place(stack)
      }
    else
      %__MODULE__{status: status(whole), class: :abnormal, reason: written(whole)}
    end
  end

  def of(reason),
    do: %__MODULE__{status: status(reason), class: :abnormal, reason: written(reason)}

  @doc "The ending of a process that was noticed gone."
  @spec unknown() :: t()
  def unknown, do: %__MODULE__{status: "unknown", class: :unknown}

  @doc "Whether it ended as a process is meant to."
  @spec ok?(t()) :: boolean() | nil
  def ok?(%__MODULE__{class: :normal}), do: true
  def ok?(%__MODULE__{class: :unknown}), do: nil
  def ok?(%__MODULE__{}), do: false

  @doc "How it ended, in words: `exited normal`, `killed`, `crashed: RuntimeError`."
  @spec words(t()) :: String.t()
  def words(%__MODULE__{class: :killed}), do: "killed"
  def words(%__MODULE__{class: :crashed, status: status}), do: "crashed: #{status}"
  def words(%__MODULE__{class: :unknown}), do: "gone"
  def words(%__MODULE__{status: status}), do: "exited #{status}"

  defp frame?({module, function, arity, location})
       when is_atom(module) and is_atom(function) and (is_integer(arity) or is_list(arity)) and
              is_list(location),
       do: true

  defp frame?(_), do: false

  # The first word of a reason: few enough of them that every exit of one
  # kind can be found by it.
  defp status(reason) when is_atom(reason),
    do: reason |> TimelessBeamAcct.Identity.text() |> short()

  defp status(%module{__exception__: true}),
    do: module |> TimelessBeamAcct.Identity.text() |> short()

  defp status(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: reason |> elem(0) |> status()

  defp status(_), do: "other"

  defp short(text), do: String.slice(text, 0, @status_length)

  defp raised(%{__exception__: true} = exception) do
    "#{TimelessBeamAcct.Identity.text(exception.__struct__)}: #{Exception.message(exception)}"
    |> cut()
  rescue
    _ -> written(exception)
  end

  defp raised(reason), do: written(reason)

  defp written(reason), do: reason |> inspect(limit: 8, printable_limit: 120) |> cut()

  defp cut(text) do
    if String.length(text) > @reason_length,
      do: String.slice(text, 0, @reason_length - 1) <> "…",
      else: text
  end

  defp place([{module, function, arity, location} | _]) do
    arity = if is_list(arity), do: length(arity), else: arity

    Exception.format_stacktrace_entry(
      {module, function, arity, Keyword.take(location, [:file, :line])}
    )
  rescue
    _ -> nil
  end
end
