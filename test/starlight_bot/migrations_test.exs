defmodule StarlightBot.MigrationsTest do
  use ExUnit.Case, async: false

  @migrations_path Path.join([:code.priv_dir(:starlight_bot), "repo", "migrations"])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StarlightBot.Repo)
    :ok
  end

  test "all migration files were applied to the test database" do
    files = Path.wildcard(Path.join(@migrations_path, "*.exs"))
    assert length(files) > 0, "No migration files found in #{@migrations_path}"

    {:ok, %{rows: [[count]]}} =
      Ecto.Adapters.SQL.query(StarlightBot.Repo, "SELECT COUNT(*) FROM schema_migrations", [])

    assert count == length(files),
           "Expected #{length(files)} migrations applied, found #{count}. " <>
             "Run `mix db.reset` if the test DB is stale."
  end

  test "expected tables exist after migration" do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        StarlightBot.Repo,
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name != 'schema_migrations' ORDER BY name",
        []
      )

    tables = Enum.map(rows, fn [name] -> name end)

    expected =
      ~w[battle_strategies ego_gifts gift_strategies hooks images run_events run_logs sinner_profiles teams theme_pack_plans]

    for table <- expected do
      assert table in tables, "Expected table '#{table}' to exist after migrations. Found: #{inspect(tables)}"
    end
  end
end
