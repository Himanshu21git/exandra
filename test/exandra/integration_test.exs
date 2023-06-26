defmodule Exandra.IntegrationTest do
  use Exandra.AdapterCase, async: false, integration: true

  import Ecto.Query

  alias Exandra.TestRepo

  @keyspace "exandra_test"

  defmodule Schema do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "my_schema" do
      field :my_map, :map
      field :my_enum, Ecto.Enum, values: [:foo, :bar], default: :bar
      field :my_exandra_map, Exandra.Map, key: :string, value: :integer
      field :my_set, Exandra.Set, type: :integer
      field :my_udt, Exandra.UDT, type: :fullname
      field :my_list, {:array, :string}
      field :my_utc, :utc_datetime_usec
      field :my_integer, :integer
      field :my_bool, :boolean
      field :my_decimal, :decimal

      timestamps type: :utc_datetime
    end
  end

  defmodule CounterSchema do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "my_counter_schema" do
      field :my_counter, Exandra.Counter
    end
  end

  setup_all do
    opts = [keyspace: @keyspace, hostname: "localhost", port: @port, sync_connect: 1000]

    stub_with_real_modules()
    create_keyspace(@keyspace)

    on_exit(fn ->
      stub_with_real_modules()
      drop_keyspace(@keyspace)
    end)

    {:ok, conn} = Xandra.start_link(Keyword.drop(opts, [:keyspace]))
    Xandra.execute!(conn, "USE #{@keyspace}")
    Xandra.execute!(conn, "CREATE TYPE IF NOT EXISTS fullname (first_name text, last_name text)")
    Xandra.execute!(conn, "DROP TABLE IF EXISTS my_schema")
    Xandra.execute!(conn, "DROP TABLE IF EXISTS my_counter_schema")

    Xandra.execute!(conn, """
    CREATE TABLE my_schema (
      id uuid,
      my_map text,
      my_enum varchar,
      my_exandra_map map<varchar, int>,
      my_set set<int>,
      my_udt fullname,
      my_list list<varchar>,
      my_utc timestamp,
      my_integer int,
      my_bool boolean,
      my_decimal decimal,
      inserted_at timestamp,
      updated_at timestamp,
      PRIMARY KEY (id)
    )
    """)

    Xandra.execute!(conn, """
    CREATE TABLE my_counter_schema (
      id uuid,
      my_counter counter,
      PRIMARY KEY (id)
    )
    """)

    :ok = Xandra.stop(conn)

    %{start_opts: opts}
  end

  setup do
    truncate_all_tables(@keyspace)
    :ok
  end

  describe "all/1" do
    test "returns empty list when no rows exist", %{start_opts: start_opts} do
      start_supervised!({TestRepo, start_opts})
      assert TestRepo.all(Schema) == []
    end
  end

  test "inserting and querying data", %{start_opts: start_opts} do
    start_supervised!({TestRepo, start_opts})

    row1_id = Ecto.UUID.generate()
    row2_id = Ecto.UUID.generate()
    set1 = MapSet.new([1])
    set2 = MapSet.new([1, 2, 3])

    schema1 = %Schema{
      id: row1_id,
      my_map: %{},
      my_exandra_map: %{"this" => 1},
      my_set: set1,
      my_list: ["a", "b", "c"],
      my_udt: %{"first_name" => "frank", "last_name" => "beans"},
      my_bool: true,
      my_integer: 4
    }

    schema2 = %Schema{
      id: row2_id,
      my_map: %{"a" => "b"},
      my_exandra_map: %{"that" => 2},
      my_set: set2,
      my_list: ["1", "2", "3"],
      my_udt: %{"first_name" => "frank", "last_name" => "beans"},
      my_bool: false,
      my_integer: 5
    }

    TestRepo.insert!(schema1)
    TestRepo.insert!(schema2)

    assert [returned_schema1, returned_schema2] =
             Schema |> TestRepo.all() |> Enum.sort_by(& &1.my_integer)

    assert %Schema{
             id: ^row1_id,
             my_map: %{},
             my_exandra_map: %{"this" => 1},
             my_set: ^set1,
             my_list: ["a", "b", "c"],
             my_udt: %{"first_name" => "frank", "last_name" => "beans"},
             my_bool: true,
             my_integer: 4
           } = returned_schema1

    assert %Schema{
             id: ^row2_id,
             my_map: %{"a" => "b"},
             my_exandra_map: %{"that" => 2},
             my_set: ^set2,
             my_list: ["1", "2", "3"],
             my_udt: %{"first_name" => "frank", "last_name" => "beans"},
             my_bool: false,
             my_integer: 5
           } = returned_schema2

    counter_id = Ecto.UUID.generate()

    query =
      from c in CounterSchema,
        update: [set: [my_counter: c.my_counter + 3]],
        where: c.id == ^counter_id

    assert {1, _} = TestRepo.update_all(query, [])

    assert %CounterSchema{} = fetched_counter = TestRepo.get!(CounterSchema, counter_id)
    assert fetched_counter.id == counter_id
    assert fetched_counter.my_counter == 3

    # Let's run the query again and see the counter updated, since that's what counters do.
    assert {1, _} = TestRepo.update_all(query, [])
    assert TestRepo.reload!(fetched_counter).my_counter == 6
  end
end
