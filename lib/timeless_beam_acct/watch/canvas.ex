defmodule TimelessBeamAcct.Watch.Canvas do
  @moduledoc """
  A screen, as the characters on it and how each is drawn.

  What is drawn is drawn here first, and written to the terminal as a
  whole: a frame is either on the screen or it is not. It is also how the
  screen is printed as text, and how a test reads it.

  A place is `{column, row}`, from the top left, which is `{0, 0}`. An
  area is `{column, row, width, height}`. What is drawn outside the canvas
  is not drawn.

  A style is a list of what it is: a colour, `:bold`, `:reversed`. One
  character is taken to be one column wide.
  """

  @type style :: [
          :bold
          | :reversed
          | :dark_gray
          | :red
          | :green
          | :yellow
          | :blue
          | :magenta
          | :cyan
        ]
  @type area :: {integer(), integer(), integer(), integer()}
  @type span :: {String.t(), style()} | String.t()
  @type t :: %__MODULE__{
          width: non_neg_integer(),
          height: non_neg_integer(),
          cells: %{{integer(), integer()} => {String.t(), style()}}
        }

  defstruct width: 0, height: 0, cells: %{}

  @bars {" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}

  @spec new(non_neg_integer(), non_neg_integer()) :: t()
  def new(width, height), do: %__MODULE__{width: width, height: height}

  @doc "The whole of it, as an area."
  @spec area(t()) :: area()
  def area(%__MODULE__{width: width, height: height}), do: {0, 0, width, height}

  @doc """
  Write a text from a place rightwards, in at most `room` columns. What
  does not fit is left out.
  """
  @spec put(t(), integer(), integer(), String.t(), style(), integer() | nil) :: t()
  def put(canvas, x, y, text, style \\ [], room \\ nil)

  def put(%__MODULE__{height: height} = canvas, _x, y, _text, _style, _room)
      when y < 0 or y >= height,
      do: canvas

  def put(%__MODULE__{} = canvas, x, y, text, style, room) do
    room = min(room || canvas.width, canvas.width - x)
    style = Enum.sort(style)

    cells =
      text
      |> String.graphemes()
      |> Enum.take(max(room, 0))
      |> Enum.with_index(x)
      |> Enum.reduce(canvas.cells, fn
        {_char, at}, cells when at < 0 -> cells
        {char, at}, cells -> Map.put(cells, {at, y}, {char, style})
      end)

    %{canvas | cells: cells}
  end

  @doc """
  Write texts one after another, each in its own style, and return the
  canvas and the column after the last.
  """
  @spec spans(t(), integer(), integer(), [span()], integer() | nil) :: {t(), integer()}
  def spans(canvas, x, y, spans, room \\ nil) do
    stop = x + min(room || canvas.width, canvas.width - x)

    Enum.reduce(spans, {canvas, x}, fn span, {canvas, at} ->
      {text, style} = styled(span)
      {put(canvas, at, y, text, style, max(stop - at, 0)), at + String.length(text)}
    end)
  end

  @doc "How many columns these texts take."
  @spec length([span()]) :: non_neg_integer()
  def length(spans),
    do: spans |> Enum.map(&String.length(elem(styled(&1), 0))) |> Enum.sum()

  defp styled({text, style}), do: {text, style}
  defp styled(text) when is_binary(text), do: {text, []}

  @doc "Write texts so that the last ends where the area does."
  @spec right(t(), area(), integer(), [span()]) :: t()
  def right(canvas, {x, _y, width, _height}, y, spans) do
    start = max(x + width - __MODULE__.length(spans), x)
    canvas |> spans(start, y, spans, x + width - start) |> elem(0)
  end

  @doc "Write texts in the middle of the area."
  @spec centered(t(), area(), integer(), [span()]) :: t()
  def centered(canvas, {x, _y, width, _height}, y, spans) do
    start = max(x + div(width - __MODULE__.length(spans), 2), x)
    canvas |> spans(start, y, spans, x + width - start) |> elem(0)
  end

  @doc "Put nothing where something was: what a thing drawn over the rest is drawn on."
  @spec clear(t(), area()) :: t()
  def clear(%__MODULE__{} = canvas, {x, y, width, height}) do
    cells =
      for column <- x..(x + width - 1)//1, row <- y..(y + height - 1)//1, reduce: canvas.cells do
        cells -> Map.delete(cells, {column, row})
      end

    %{canvas | cells: cells}
  end

  @doc "Draw every character of a row another way as well: the row that is picked."
  @spec restyle(t(), area(), style()) :: t()
  def restyle(%__MODULE__{} = canvas, {x, y, width, height}, more) do
    cells =
      for column <- x..(x + width - 1)//1,
          row <- y..(y + height - 1)//1,
          column >= 0 and column < canvas.width and row >= 0 and row < canvas.height,
          reduce: canvas.cells do
        cells ->
          {char, style} = Map.get(cells, {column, row}, {" ", []})
          Map.put(cells, {column, row}, {char, Enum.sort(Enum.uniq(more ++ style))})
      end

    %{canvas | cells: cells}
  end

  @doc """
  A frame around an area, with what is said on it, and the area inside
  it.

    * `:title`, `:right`: on the top line, at the left and at the right
    * `:bottom`, `:bottom_center`, `:bottom_right`: on the bottom line
  """
  @spec box(t(), area(), keyword()) :: {t(), area()}
  def box(canvas, {x, y, width, height} = area, said \\ []) do
    if width < 2 or height < 2 do
      {canvas, {x, y, 0, 0}}
    else
      line = String.duplicate("─", width - 2)
      inside = {x + 1, y, width - 2, 1}
      below = {x + 1, y + height - 1, width - 2, 1}

      canvas =
        canvas
        |> put(x, y, "┌" <> line <> "┐")
        |> put(x, y + height - 1, "└" <> line <> "┘")

      canvas =
        Enum.reduce((y + 1)..(y + height - 2)//1, canvas, fn row, canvas ->
          canvas |> put(x, row, "│") |> put(x + width - 1, row, "│")
        end)

      canvas =
        said
        |> Enum.reduce(canvas, fn
          {_where, nil}, canvas ->
            canvas

          {_where, []}, canvas ->
            canvas

          {:title, spans}, canvas ->
            canvas |> spans(x + 1, y, spans, width - 2) |> elem(0)

          {:right, spans}, canvas ->
            right(canvas, inside, y, spans)

          {:bottom, spans}, canvas ->
            canvas |> spans(x + 1, y + height - 1, spans, width - 2) |> elem(0)

          {:bottom_center, spans}, canvas ->
            centered(canvas, below, y + height - 1, spans)

          {:bottom_right, spans}, canvas ->
            right(canvas, below, y + height - 1, spans)
        end)

      _ = area
      {canvas, {x + 1, y + 1, width - 2, height - 2}}
    end
  end

  @doc """
  Figures as bars, one to a column, the highest as tall as the area.

  With nothing above nought there is nothing to draw, and nothing is
  drawn.
  """
  @spec sparkline(t(), area(), [number()], style()) :: t()
  def sparkline(canvas, {x, y, width, height}, figures, style \\ []) do
    figures = Enum.take(figures, max(width, 0))
    highest = Enum.max(figures, fn -> 0 end)

    if highest <= 0 or height <= 0 do
      canvas
    else
      figures
      |> Enum.with_index(x)
      |> Enum.reduce(canvas, fn {figure, column}, canvas ->
        eighths = trunc(max(figure, 0) * height * 8 / highest)

        Enum.reduce(0..(height - 1), canvas, fn up, canvas ->
          case min(max(eighths - up * 8, 0), 8) do
            0 -> canvas
            part -> put(canvas, column, y + height - 1 - up, elem(@bars, part), style, 1)
          end
        end)
      end)
    end
  end

  @doc """
  A table: a line of headings, and the rows under it, the picked row kept
  in sight and drawn the other way round.

  A column is `{:length, columns}`, which is as wide as it says, or
  `{:min, columns}`, which takes what is left over as well. A cell is
  `{text, style}` or `{:right, text, style}`, which is set to the right of
  its column.
  """
  @spec table(
          t(),
          area(),
          [String.t()],
          [{:length | :min, non_neg_integer()}],
          [list()],
          keyword()
        ) ::
          t()
  def table(canvas, {x, y, width, height}, headings, columns, rows, opts \\ []) do
    widths = widths(columns, width)
    picked = Keyword.get(opts, :picked)
    heading_style = Keyword.get(opts, :heading, [:dark_gray])
    shown = max(height - 1, 0)

    from =
      case picked do
        nil -> 0
        picked -> max(picked - shown + 1, 0)
      end

    canvas = row(canvas, x, y, widths, Enum.map(headings, &{&1, heading_style}))

    rows
    |> Enum.drop(from)
    |> Enum.take(shown)
    |> Enum.with_index()
    |> Enum.reduce(canvas, fn {cells, index}, canvas ->
      canvas = row(canvas, x, y + 1 + index, widths, cells)

      if picked == from + index,
        do: restyle(canvas, {x, y + 1 + index, width, 1}, [:reversed]),
        else: canvas
    end)
  end

  defp row(canvas, x, y, widths, cells) do
    {canvas, _at} =
      widths
      |> Enum.zip(cells)
      |> Enum.reduce({canvas, x}, fn
        {width, {:right, text, style}}, {canvas, at} ->
          text = String.slice(text, 0, width)
          {put(canvas, at + width - String.length(text), y, text, style, width), at + width + 1}

        {width, {text, style}}, {canvas, at} ->
          {put(canvas, at, y, text, style, width), at + width + 1}
      end)

    canvas
  end

  # What is left over goes to the columns that take it, in turn; and what
  # there is too little of is taken from them.
  defp widths(columns, width) do
    asked = columns |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    left = width - asked - max(Kernel.length(columns) - 1, 0)
    takers = Enum.count(columns, &match?({:min, _}, &1))

    {widths, _} =
      Enum.map_reduce(columns, {left, takers}, fn
        {:length, columns}, left ->
          {columns, left}

        {:min, columns}, {_left, 0} ->
          {columns, {0, 0}}

        {:min, columns}, {left, takers} ->
          share =
            if left >= 0,
              do: div(left + takers - 1, takers),
              else: -div(-left + takers - 1, takers)

          {max(columns + share, 0), {left - share, takers - 1}}
      end)

    widths
  end

  ## Out

  @doc "The screen as the text on it, a line to a row, with nothing trailing."
  @spec text(t()) :: [String.t()]
  def text(%__MODULE__{} = canvas) do
    for y <- 0..(canvas.height - 1)//1 do
      0..(canvas.width - 1)//1
      |> Enum.map(fn x -> canvas.cells |> Map.get({x, y}, {" ", []}) |> elem(0) end)
      |> IO.iodata_to_binary()
      |> String.trim_trailing()
    end
  end

  @doc """
  The screen as what a terminal is sent to draw it, a row at a time. Each
  row is whole: it needs nothing of the row before it.
  """
  @spec rows(t()) :: [binary()]
  def rows(%__MODULE__{} = canvas) do
    for y <- 0..(canvas.height - 1)//1 do
      {runs, style, text} =
        Enum.reduce(0..(canvas.width - 1)//1, {[], [], []}, fn x, {runs, style, text} ->
          case Map.get(canvas.cells, {x, y}, {" ", []}) do
            {char, ^style} -> {runs, style, [text, char]}
            {char, other} -> {[runs, sgr(style), text], other, [char]}
          end
        end)

      IO.iodata_to_binary([runs, sgr(style), text, "\e[0m"])
    end
  end

  defp sgr([]), do: "\e[0m"
  defp sgr(style), do: ["\e[0;", style |> Enum.map(&code/1) |> Enum.intersperse(";"), "m"]

  defp code(:bold), do: "1"
  defp code(:reversed), do: "7"
  defp code(:dark_gray), do: "90"
  defp code(:red), do: "31"
  defp code(:green), do: "32"
  defp code(:yellow), do: "33"
  defp code(:blue), do: "34"
  defp code(:magenta), do: "35"
  defp code(:cyan), do: "36"
end
