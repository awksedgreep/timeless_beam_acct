defmodule TimelessBeamAcct.Collect.EtsTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.{Batch, Options}
  alias TimelessBeamAcct.Collect.Ets

  defp collector(max_tables), do: Ets.new(Options.new!(max_tables: max_tables))

  defp report(state, tables) do
    {state, batch, by_owner} = Ets.report(state, Batch.new(0), tables)
    {state, by_table(batch), by_owner}
  end

  # `%{table => %{bytes: _, objects: _, tables: _}}`
  defp by_table(%Batch{} = batch) do
    samples = Batch.samples(batch)
    series = Enum.map(samples, fn {name, labels, _} -> {name, labels} end)
    assert series == Enum.uniq(series), "a series was reported twice"

    Enum.reduce(samples, %{}, fn {name, [{"table", table}], value}, tables ->
      key =
        case name do
          "beam_ets_memory_bytes" -> :bytes
          "beam_ets_objects" -> :objects
          "beam_ets_tables" -> :tables
        end

      Map.update(tables, table, %{key => value}, &Map.put(&1, key, value))
    end)
  end

  describe "from readings written by hand" do
    test "tables of one name are added together, and counted" do
      owner = self()

      {_state, tables, _} =
        report(collector(10), [
          {:connection, 1_000, 10, owner},
          {:cache, 500, 3, owner},
          {:connection, 2_000, 20, owner},
          {:connection, 4_000, 0, owner}
        ])

      assert tables == %{
               "connection" => %{bytes: 7_000, objects: 30, tables: 3},
               "cache" => %{bytes: 500, objects: 3, tables: 1}
             }
    end

    test "a name is written as Elixir writes it, without the colon" do
      assert Ets.label(:my_table) == "my_table"
      assert Ets.label(MyApp.Cache) == "MyApp.Cache"
      assert Ets.label(:"Elixir.MyApp.Cache") == "MyApp.Cache"
      assert Ets.label(:ac_tab) == "ac_tab"
      assert Ets.label(:undefined) == "undefined"
      assert Ets.label(nil) == "nil"
      # What is not a plain atom is written as it has to be.
      assert Ets.label(:"two words") == "two words"

      {_state, tables, _} = report(collector(10), [{MyApp.Cache, 8, 1, self()}])
      assert Map.keys(tables) == ["MyApp.Cache"]
    end

    test "the names with the most memory are reported, and the rest together as other" do
      owner = self()

      {_state, tables, _} =
        report(collector(2), [
          {:small, 10, 1, owner},
          {:large, 5_000, 50, owner},
          {:split, 2_000, 5, owner},
          {:split, 2_000, 5, owner},
          {:medium, 3_000, 9, owner},
          {:small, 10, 1, owner}
        ])

      # `split` is two tables that together are larger than `medium`.
      assert tables == %{
               "large" => %{bytes: 5_000, objects: 50, tables: 1},
               "split" => %{bytes: 4_000, objects: 10, tables: 2},
               "other" => %{bytes: 3_020, objects: 11, tables: 3}
             }
    end

    test "the series add up to every table there is" do
      tables = for n <- 1..50, do: {:"table_#{rem(n, 17)}", n * 100, n, self()}
      {_state, reported, _} = report(collector(5), tables)

      assert map_size(reported) == 6
      assert reported |> Map.values() |> Enum.map(& &1.bytes) |> Enum.sum() == 127_500
      assert reported |> Map.values() |> Enum.map(& &1.objects) |> Enum.sum() == 1_275
      assert reported |> Map.values() |> Enum.map(& &1.tables) |> Enum.sum() == 50
    end

    test "there is no other when every name has a place" do
      {_state, tables, _} = report(collector(2), [{:a, 1, 1, self()}, {:b, 2, 2, self()}])
      assert tables |> Map.keys() |> Enum.sort() == ["a", "b"]
    end

    test "with no room, everything is other" do
      {_state, tables, _} = report(collector(0), [{:a, 1, 1, self()}, {:b, 2, 2, self()}])
      assert tables == %{"other" => %{bytes: 3, objects: 3, tables: 2}}
    end

    test "a name that has a place keeps it when another grows larger" do
      owner = self()
      state = collector(1)

      {state, tables, _} = report(state, [{:first, 500, 1, owner}, {:second, 100, 1, owner}])
      assert tables["first"].bytes == 500
      assert tables["other"].bytes == 100

      {_state, tables, _} = report(state, [{:first, 500, 1, owner}, {:second, 90_000, 1, owner}])
      assert tables["first"].bytes == 500
      assert tables["other"].bytes == 90_000
      refute is_map_key(tables, "second")
    end

    test "a name that is absent is reported as nothing, and has its place when it is back" do
      owner = self()
      state = collector(1)
      nothing = %{bytes: 0, objects: 0, tables: 0}

      {state, _tables, _} = report(state, [{:pool, 500, 1, owner}, {:cache, 100, 1, owner}])
      {state, tables, _} = report(state, [{:cache, 100, 1, owner}])

      # Its last sample would otherwise say it holds what it last held.
      assert tables == %{
               "pool" => nothing,
               "other" => %{bytes: 100, objects: 1, tables: 1}
             }

      {_state, tables, _} = report(state, [{:pool, 5, 1, owner}, {:cache, 100, 1, owner}])
      assert tables["pool"].bytes == 5
      assert tables["other"].bytes == 100
    end

    test "a name that has lost its place is no longer reported" do
      owner = self()
      state = collector(1)
      {state, _, _} = report(state, [{:pool, 500, 1, owner}])

      # For as many readings as a name is waited for, and one more.
      {state, reported} =
        Enum.reduce(1..7, {state, []}, fn _, {state, reported} ->
          {state, tables, _} = report(state, [])
          {state, [tables | reported]}
        end)

      [last | earlier] = reported
      assert last == %{}
      assert Enum.all?(earlier, &(&1 == %{"pool" => %{bytes: 0, objects: 0, tables: 0}}))

      {_state, tables, _} = report(state, [{:cache, 100, 1, owner}])
      assert Map.keys(tables) == ["cache"]
    end

    test "once there has been an other, there is one at every reading" do
      owner = self()
      state = collector(1)

      {state, tables, _} = report(state, [{:pool, 500, 1, owner}])
      refute is_map_key(tables, "other")

      {state, _, _} = report(state, [{:pool, 500, 1, owner}, {:cache, 100, 1, owner}])
      {_state, tables, _} = report(state, [{:pool, 500, 1, owner}])
      assert tables["other"] == %{bytes: 0, objects: 0, tables: 0}
    end

    test "memory by owner is over all tables, whether reported by name or not" do
      one = self()
      two = spawn(fn -> :ok end)

      {_state, tables, by_owner} =
        report(collector(1), [
          {:a, 1_000, 1, one},
          {:b, 200, 1, one},
          {:c, 30, 1, two},
          {:a, 4, 1, two}
        ])

      assert by_owner == %{one => 1_200, two => 34}
      assert Map.keys(tables) |> Enum.sort() == ["a", "other"]
    end

    test "a table named other is counted with the others" do
      owner = self()

      {_state, tables, by_owner} =
        report(collector(5), [{:other, 9_000, 9, owner}, {:a, 100, 1, owner}])

      assert tables == %{
               "a" => %{bytes: 100, objects: 1, tables: 1},
               "other" => %{bytes: 9_000, objects: 9, tables: 1}
             }

      assert by_owner == %{owner => 9_100}

      {_state, tables, _} =
        report(collector(1), [{:other, 9_000, 9, owner}, {:a, 100, 1, owner}, {:b, 10, 1, owner}])

      assert tables["other"] == %{bytes: 9_010, objects: 10, tables: 2}
    end

    test "with no tables there is nothing to report" do
      {_state, batch, by_owner} = Ets.report(collector(5), Batch.new(0), [])
      assert batch.count == 0
      assert by_owner == %{}
    end
  end

  describe "on the live VM" do
    test "a table's memory is in bytes, and tables of one name are added together" do
      name = :"ets_test_#{System.unique_integer([:positive])}"
      one = :ets.new(name, [:set])
      two = :ets.new(name, [:bag])
      :ets.insert(one, for(n <- 1..100, do: {n, :binary.copy("x", 100)}))
      :ets.insert(two, [{:a, 1}, {:a, 2}, {:b, 3}])

      words = :ets.info(one, :memory) + :ets.info(two, :memory)
      bytes = words * :erlang.system_info(:wordsize)

      {state, batch, by_owner} = Ets.collect(collector(100_000), Batch.new(0))
      tables = by_table(batch)

      assert tables[Atom.to_string(name)] == %{bytes: bytes, objects: 103, tables: 2}
      # This process owns those two and no others.
      assert by_owner[self()] == bytes
      refute is_map_key(tables, "other")

      assert Ets.close(state) == :ok
    end

    test "every table of the VM is in the count, and every figure is a whole number" do
      {_state, batch, by_owner} = Ets.collect(collector(3), Batch.new(0))

      for {name, [{"table", table}], value} <- Batch.samples(batch) do
        assert is_integer(value) and value >= 0, "#{name} of #{table} is #{inspect(value)}"
      end

      tables = by_table(batch)
      assert map_size(tables) <= 4
      # The VM has tables of its own, of more than three names.
      assert tables["other"].tables > 0

      for {owner, bytes} <- by_owner do
        assert is_pid(owner)
        assert is_integer(bytes) and bytes > 0
      end

      # Both are of the one reading, whatever other tests did meanwhile.
      assert by_owner |> Map.values() |> Enum.sum() ==
               tables |> Map.values() |> Enum.map(& &1.bytes) |> Enum.sum()
    end

    test "a table that is gone by the time it is read is left out" do
      here = :ets.new(:ets_test_here, [])
      gone = :ets.new(:ets_test_gone, [])
      :ets.delete(gone)

      assert [{:ets_test_here, bytes, 0, owner}] = Ets.read([gone, here, :ets_test_never_was])
      assert owner == self()
      assert bytes == :ets.info(here, :memory) * :erlang.system_info(:wordsize)
    end

    test "a table may be named undefined" do
      table = :ets.new(:undefined, [])
      assert [{:undefined, _bytes, 0, _owner}] = Ets.read([table])
    end
  end
end
