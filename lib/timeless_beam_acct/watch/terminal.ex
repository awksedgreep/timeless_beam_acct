defmodule TimelessBeamAcct.Watch.Terminal do
  @moduledoc """
  The terminal: taken so that a key is read as it is pressed, and put
  back as it was.

  There is nothing here but what the VM and `stty` give. From OTP 28 the
  VM reads a terminal a key at a time when asked to. Before that it reads
  what the terminal gives it, and the terminal is told to give it a key
  at a time.

  ## Keys

  | key | is |
  |---|---|
  | a letter, a digit, a sign | `{:char, "a"}` |
  | the arrows | `:up`, `:down`, `:left`, `:right` |
  | an arrow with shift | `{:shift, :left}` |
  | | `:enter`, `:esc`, `:tab`, `:backtab`, `:backspace`, `:delete` |
  | | `:home`, `:end`, `:page_up`, `:page_down` |
  | control and C | `:ctrl_c` |
  """

  alias TimelessBeamAcct.Watch.Canvas

  @type key ::
          {:char, String.t()}
          | {:shift, atom()}
          | :up
          | :down
          | :left
          | :right
          | :enter
          | :esc
          | :tab
          | :backtab
          | :backspace
          | :delete
          | :home
          | :end
          | :page_up
          | :page_down
          | :ctrl_c

  @type t :: %__MODULE__{
          tty: String.t(),
          saved: String.t(),
          raw: boolean(),
          reader: pid(),
          drawn: [binary()],
          size: {non_neg_integer(), non_neg_integer()}
        }

  defstruct [:tty, :saved, :raw, :reader, drawn: [], size: {0, 0}]

  # How long the rest of a key that began with escape is waited for. A
  # terminal sends an arrow as escape and two more, all at once; a person
  # who presses escape sends it alone.
  @rest_ms 30

  ## Taking it and giving it back

  @doc """
  Take the terminal. `{:error, why}` where there is none to take.
  """
  @spec start() :: {:ok, t()} | {:error, String.t()}
  def start do
    with {:ok, tty} <- tty(),
         {:ok, saved} <- saved(tty),
         {:ok, raw} <- raw() do
      stty(tty, if(raw, do: "-isig", else: "raw -echo -isig"))
      :io.setopts(:standard_io, encoding: :unicode)
      owner = self()
      reader = spawn_link(fn -> read(owner) end)
      IO.write("\e[?1049h\e[?25l\e[2J")
      {:ok, %__MODULE__{tty: tty, saved: saved, raw: raw, reader: reader}}
    end
  end

  @doc "Put the terminal back as it was."
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = terminal) do
    Process.unlink(terminal.reader)
    Process.exit(terminal.reader, :kill)
    IO.write("\e[0m\e[?25h\e[?1049l")
    stty(terminal.tty, terminal.saved)
    if terminal.raw, do: interactive({:noshell, :cooked})
    :ok
  end

  # The terminal this was started from, as a path: `stty` is a process of
  # its own, and has to be told which terminal it is asked about.
  defp tty do
    path =
      case File.read_link("/proc/self/fd/0") do
        {:ok, path} ->
          path

        _ ->
          case ~c"ps -o tty= -p #{System.pid()}" |> :os.cmd() |> to_string() |> String.trim() do
            "" -> ""
            "?" <> _ -> ""
            name -> "/dev/" <> name
          end
      end

    if String.starts_with?(path, "/dev/") and match?({:ok, _}, :io.columns()),
      do: {:ok, path},
      else: {:error, "not a terminal: `--print 120x40` draws the screen once, as text"}
  end

  defp saved(tty) do
    case stty(tty, "-g") do
      "" -> {:error, "the terminal would not say how it is set: is `stty` there?"}
      saved -> if saved =~ ~r/\A[0-9a-f:=]+\z/i, do: {:ok, saved}, else: {:error, saved}
    end
  end

  defp stty(tty, what) do
    ~c"stty #{what} < #{tty} 2>&1" |> :os.cmd() |> to_string() |> String.trim()
  end

  # Whether the VM reads a key at a time itself.
  defp raw do
    if String.to_integer(System.otp_release()) >= 28 do
      case interactive({:noshell, :raw}) do
        :ok ->
          {:ok, true}

        {:error, :already_started} ->
          {:error,
           "a shell has the terminal: run this as `mix timeless_beam_acct.watch`, and not from iex"}

        other ->
          {:error, "the terminal could not be taken: #{inspect(other)}"}
      end
    else
      {:ok, false}
    end
  end

  defp interactive(how) do
    apply(:shell, :start_interactive, [how])
  catch
    kind, what -> {kind, what}
  end

  ## Size

  @doc "Columns and rows."
  @spec size() :: {pos_integer(), pos_integer()}
  def size do
    with {:ok, columns} <- :io.columns(),
         {:ok, rows} <- :io.rows() do
      {columns, rows}
    else
      _ -> {80, 24}
    end
  end

  ## Drawing

  @doc """
  Draw a screen. Only the rows that are not as they were drawn last are
  sent.
  """
  @spec draw(t(), Canvas.t()) :: t()
  def draw(%__MODULE__{} = terminal, %Canvas{} = canvas) do
    size = {canvas.width, canvas.height}
    rows = Canvas.rows(canvas)
    # A terminal of another size has been cleared of what was drawn.
    before = if size == terminal.size, do: terminal.drawn, else: []

    out =
      rows
      |> Enum.with_index(1)
      |> Enum.zip(Stream.concat(before, Stream.repeatedly(fn -> nil end)))
      |> Enum.flat_map(fn
        {{row, _at}, row} -> []
        {{row, at}, _was} -> ["\e[", Integer.to_string(at), ";1H", row]
      end)

    clear = if size == terminal.size, do: [], else: "\e[0m\e[2J"
    if out != [] or clear != [], do: IO.write([clear, out])
    %{terminal | drawn: rows, size: size}
  end

  ## Reading

  defp read(owner) do
    case :io.get_chars(:standard_io, ~c"", 1) do
      :eof ->
        send(owner, {__MODULE__, :eof})

      {:error, _} ->
        send(owner, {__MODULE__, :eof})

      chars ->
        send(owner, {__MODULE__, :chars, IO.chardata_to_string(chars)})
        read(owner)
    end
  end

  @doc """
  The keys that were pressed, waiting `timeout` milliseconds for the
  first of them: every one that is waiting, and `[]` if none came.

  `:eof` if the terminal has gone.
  """
  @spec keys(t(), non_neg_integer()) :: [key()] | :eof
  def keys(%__MODULE__{}, timeout) do
    receive do
      {__MODULE__, :chars, chars} -> gather(chars)
      {__MODULE__, :eof} -> :eof
    after
      timeout -> []
    end
  end

  defp gather(chars) do
    receive do
      {__MODULE__, :chars, more} -> gather(chars <> more)
    after
      0 ->
        case decode(chars) do
          {keys, ""} ->
            keys

          {keys, rest} ->
            receive do
              {__MODULE__, :chars, more} -> keys ++ gather(rest <> more)
            after
              @rest_ms -> keys ++ alone(rest)
            end
        end
    end
  end

  # What began as a key of several characters and was not one.
  defp alone("\e" <> rest), do: [:esc | rest |> decode() |> elem(0)]
  defp alone(_rest), do: []

  @doc """
  The keys that characters are, and what is left: the beginning of a key
  the rest of which has not come.
  """
  @spec decode(String.t()) :: {[key()], String.t()}
  def decode(chars), do: decode(chars, [])

  defp decode("", keys), do: {Enum.reverse(keys), ""}

  defp decode("\e[" <> rest = all, keys) do
    case Regex.run(~r/\A([0-9;]*)([@-~])/, rest) do
      [whole, given, final] ->
        rest = binary_part(rest, byte_size(whole), byte_size(rest) - byte_size(whole))

        case sequence(given, final) do
          nil -> decode(rest, keys)
          key -> decode(rest, [key | keys])
        end

      nil ->
        if rest =~ ~r/\A[0-9;]*\z/, do: {Enum.reverse(keys), all}, else: decode(rest, keys)
    end
  end

  defp decode("\eO", keys), do: {Enum.reverse(keys), "\eO"}

  defp decode("\eO" <> <<final::utf8, rest::binary>>, keys) do
    case sequence("", <<final::utf8>>) do
      nil -> decode(rest, keys)
      key -> decode(rest, [key | keys])
    end
  end

  defp decode("\e", keys), do: {Enum.reverse(keys), "\e"}
  defp decode("\e" <> rest, keys), do: decode(rest, [:esc | keys])
  defp decode(<<3, rest::binary>>, keys), do: decode(rest, [:ctrl_c | keys])
  defp decode("\r\n" <> rest, keys), do: decode(rest, [:enter | keys])
  defp decode("\r" <> rest, keys), do: decode(rest, [:enter | keys])
  defp decode("\n" <> rest, keys), do: decode(rest, [:enter | keys])
  defp decode("\t" <> rest, keys), do: decode(rest, [:tab | keys])
  defp decode(<<127, rest::binary>>, keys), do: decode(rest, [:backspace | keys])
  defp decode(<<8, rest::binary>>, keys), do: decode(rest, [:backspace | keys])
  # Another key held with control is not a key here.
  defp decode(<<control, rest::binary>>, keys) when control < 32, do: decode(rest, keys)

  defp decode(chars, keys) do
    case String.next_grapheme(chars) do
      {char, rest} -> decode(rest, [{:char, char} | keys])
      nil -> {Enum.reverse(keys), ""}
    end
  end

  defp sequence("", "A"), do: :up
  defp sequence("", "B"), do: :down
  defp sequence("", "C"), do: :right
  defp sequence("", "D"), do: :left
  defp sequence("", "H"), do: :home
  defp sequence("", "F"), do: :end
  defp sequence("", "Z"), do: :backtab
  defp sequence("1", "~"), do: :home
  defp sequence("7", "~"), do: :home
  defp sequence("4", "~"), do: :end
  defp sequence("8", "~"), do: :end
  defp sequence("3", "~"), do: :delete
  defp sequence("5", "~"), do: :page_up
  defp sequence("6", "~"), do: :page_down
  # With shift, and with shift and another held as well.
  defp sequence("1;" <> held, final) when held in ["2", "4", "6", "8"] do
    case sequence("", final) do
      key when key in [:left, :right, :up, :down] -> {:shift, key}
      key -> key
    end
  end

  defp sequence("1;" <> _held, final), do: sequence("", final)
  defp sequence(_given, _final), do: nil
end
