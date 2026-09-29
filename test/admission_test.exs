defmodule TimelessBeamAcct.AdmissionTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.Admission

  test "the heaviest are given the places there are" do
    admission = Admission.new(2) |> Admission.reading(a: 1, b: 3, c: 2)
    assert Admission.member?(admission, :b)
    assert Admission.member?(admission, :c)
    refute Admission.member?(admission, :a)
    assert Admission.size(admission) == 2
  end

  test "a name that has a place keeps it, however heavy the others become" do
    admission =
      Admission.new(1)
      |> Admission.reading(a: 5, b: 1)
      |> Admission.reading(a: 1, b: 500)

    assert Admission.member?(admission, :a)
    refute Admission.member?(admission, :b)
  end

  test "an absent name keeps its place for a few readings, and then loses it" do
    admission = Admission.new(1, linger: 2) |> Admission.reading(a: 1)

    admission = admission |> Admission.reading(b: 1) |> Admission.reading(b: 1)
    assert Admission.member?(admission, :a)
    refute Admission.member?(admission, :b)

    admission = Admission.reading(admission, b: 1)
    refute Admission.member?(admission, :a)
    assert Admission.member?(admission, :b)
  end

  test "coming back is being present: the count of absences starts again" do
    admission =
      Admission.new(1, linger: 1)
      |> Admission.reading(a: 1)
      |> Admission.reading([])
      |> Admission.reading(a: 1)
      |> Admission.reading([])

    assert Admission.member?(admission, :a)
  end

  test "the names that have a place are those present and those still waited for" do
    admission =
      Admission.new(3, linger: 1)
      |> Admission.reading(a: 1, b: 1)
      |> Admission.reading(b: 1, c: 1)

    assert Enum.sort(Admission.members(admission)) == [:a, :b, :c]
    assert admission |> Admission.reading(b: 1) |> Admission.members() |> Enum.sort() == [:b, :c]
  end

  test "equals are admitted by name" do
    admission = Admission.new(2) |> Admission.reading(c: 1, a: 1, b: 1)
    assert Admission.member?(admission, :a)
    assert Admission.member?(admission, :b)
  end

  test "with no room, nothing is reported as itself" do
    admission = Admission.new(0) |> Admission.reading(a: 1)
    refute Admission.member?(admission, :a)
  end
end
