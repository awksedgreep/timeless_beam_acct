defmodule TimelessBeamAcct.Watch.TerminalTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.Watch.Terminal

  test "characters are the keys that were pressed" do
    assert Terminal.decode("aG/?") ==
             {[{:char, "a"}, {:char, "G"}, {:char, "/"}, {:char, "?"}], ""}

    assert Terminal.decode("é▲") == {[{:char, "é"}, {:char, "▲"}], ""}
    assert Terminal.decode("\r\t\d\b") == {[:enter, :tab, :backspace, :backspace], ""}
    assert Terminal.decode(<<3>>) == {[:ctrl_c], ""}
    # Another key held with control is not a key here.
    assert Terminal.decode(<<1, ?a>>) == {[{:char, "a"}], ""}
  end

  test "a key of several characters is one key" do
    assert Terminal.decode("\e[A\e[B\e[C\e[D") == {[:up, :down, :right, :left], ""}

    assert Terminal.decode("\e[H\e[F\e[1~\e[4~\eOH\eOF") ==
             {[:home, :end, :home, :end, :home, :end], ""}

    assert Terminal.decode("\e[5~\e[6~\e[3~\e[Z") ==
             {[:page_up, :page_down, :delete, :backtab], ""}

    assert Terminal.decode("\e[1;2D\e[1;2C") == {[{:shift, :left}, {:shift, :right}], ""}
    # Held with something other than shift, it is the key.
    assert Terminal.decode("\e[1;5D") == {[:left], ""}
    # One that is not known is no key, and what follows it is read.
    assert Terminal.decode("\e[99~q") == {[{:char, "q"}], ""}
  end

  test "the beginning of a key is kept until the rest of it comes" do
    assert Terminal.decode("j\e") == {[{:char, "j"}], "\e"}
    assert Terminal.decode("\e[") == {[], "\e["}
    assert Terminal.decode("\e[1;") == {[], "\e[1;"}
    assert Terminal.decode("\eO") == {[], "\eO"}
    # Escape, and then a key.
    assert Terminal.decode("\eq") == {[:esc, {:char, "q"}], ""}
  end
end
