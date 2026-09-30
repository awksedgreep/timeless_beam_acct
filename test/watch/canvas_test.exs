defmodule TimelessBeamAcct.Watch.CanvasTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.Watch.Canvas

  defp text(canvas), do: canvas |> Canvas.text() |> Enum.join("\n")

  test "a text is written from a place rightwards, and what does not fit is left out" do
    canvas =
      Canvas.new(10, 3)
      |> Canvas.put(2, 0, "héllo")
      |> Canvas.put(7, 1, "too long")
      |> Canvas.put(0, 2, "abcdef", [], 3)
      # Outside it, and not drawn.
      |> Canvas.put(0, 3, "below")
      |> Canvas.put(0, -1, "above")
      |> Canvas.put(-2, 0, "xyz")

    assert Canvas.text(canvas) == ["z héllo", "       too", "abc"]
  end

  test "texts follow one another, each in its own style" do
    {canvas, after_them} =
      Canvas.spans(Canvas.new(12, 1), 1, 0, [{"ab", [:red]}, "cd", {"ef", [:bold]}])

    assert after_them == 7
    assert text(canvas) == " abcdef"
    assert Canvas.length([{"ab", [:red]}, "cd"]) == 4

    [row] = Canvas.rows(canvas)
    assert row =~ "\e[0;31mab"
    assert row =~ "\e[0mcd"
    assert row =~ "\e[0;1mef"
    assert String.ends_with?(row, "\e[0m")
  end

  test "a frame has what is said on it, and gives the area inside it" do
    {canvas, inside} =
      Canvas.box(Canvas.new(24, 4), {0, 0, 24, 4},
        title: [" left "],
        right: [" right "],
        bottom: [" a "],
        bottom_center: [" mid "],
        bottom_right: [" z "]
      )

    assert inside == {1, 1, 22, 2}

    assert Canvas.text(canvas) == [
             "┌ left ───────── right ┐",
             "│                      │",
             "│                      │",
             "└ a ───── mid ────── z ┘"
           ]

    # Too small to be one.
    assert {_canvas, {_, _, 0, 0}} = Canvas.box(Canvas.new(5, 5), {0, 0, 1, 5})
  end

  test "figures are bars, the highest as tall as the area" do
    canvas = Canvas.sparkline(Canvas.new(5, 2), {0, 0, 5, 2}, [0, 4, 8, 12, 16])
    assert Canvas.text(canvas) == ["   ▄█", " ▄███"]

    # One row, in eighths.
    canvas = Canvas.sparkline(Canvas.new(4, 1), {0, 0, 4, 1}, [1, 2, 4, 8])
    assert Canvas.text(canvas) == ["▁▂▄█"]

    # Nothing above nought is nothing to draw.
    assert Canvas.text(Canvas.sparkline(Canvas.new(3, 1), {0, 0, 3, 1}, [0, 0, 0])) == [""]
    assert Canvas.text(Canvas.sparkline(Canvas.new(3, 1), {0, 0, 3, 1}, [])) == [""]
  end

  test "a table has its headings, and its figures to the right" do
    rows = [
      [{"one", []}, {:right, "1.5", []}, {"x", []}],
      [{"a name too long for it", []}, {:right, "22.0", []}, {"y", []}]
    ]

    canvas =
      Canvas.table(
        Canvas.new(20, 3),
        {0, 0, 20, 3},
        ["NAME", "PCT", "Z"],
        [min: 4, length: 5, length: 1],
        rows
      )

    assert Canvas.text(canvas) == [
             "NAME         PCT   Z",
             "one            1.5 x",
             "a name too l  22.0 y"
           ]
  end

  test "the picked row is drawn the other way round, and kept in sight" do
    rows = for n <- 1..10, do: [{"row #{n}", []}]

    table = fn picked ->
      Canvas.table(Canvas.new(8, 4), {0, 0, 8, 4}, ["ROW"], [min: 3], rows, picked: picked)
    end

    assert Canvas.text(table.(0)) == ["ROW", "row 1", "row 2", "row 3"]
    assert Canvas.text(table.(2)) == ["ROW", "row 1", "row 2", "row 3"]
    # Past the last that fits: it is the last shown.
    assert Canvas.text(table.(6)) == ["ROW", "row 5", "row 6", "row 7"]

    [_heading, first, _, last] = Canvas.rows(table.(6))
    refute first =~ "\e[0;7m"
    # The whole of the row, and not only what is written in it.
    assert last =~ "\e[0;7mrow 7   \e[0m"
  end

  test "what is left over goes to the columns that take it" do
    canvas =
      Canvas.table(
        Canvas.new(21, 2),
        {0, 0, 21, 2},
        ["A", "B", "C"],
        [min: 2, length: 3, min: 2],
        [[{"a", []}, {"b", []}, {"c", []}]]
      )

    assert Canvas.text(canvas) == ["A        B   C", "a        b   c"]
  end

  test "what is drawn over the rest is drawn on nothing" do
    canvas = Canvas.new(6, 2) |> Canvas.put(0, 0, "abcdef") |> Canvas.put(0, 1, "ghijkl")
    assert Canvas.text(Canvas.clear(canvas, {1, 0, 3, 2})) == ["a   ef", "g   kl"]
  end

  test "a row is whole: it needs nothing of the row before it" do
    canvas = Canvas.new(4, 2) |> Canvas.put(0, 0, "ab", [:cyan, :bold]) |> Canvas.put(0, 1, "cd")
    assert Canvas.rows(canvas) == ["\e[0m\e[0;1;36mab\e[0m  \e[0m", "\e[0mcd  \e[0m"]
  end
end
