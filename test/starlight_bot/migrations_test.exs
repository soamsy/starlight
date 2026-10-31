defmodule StarlightBot.MigrationsTest do
  use ExUnit.Case, async: false

  @expected %{
    StarlightBot.Repo =>
      ~w[app_settings battle_plans fusion_route_defaults gift_plans hook_overrides pack_plans runner_forms scheduler_settings sinner_profiles teams],
    StarlightBot.BaseRepo =>
      ~w[ego_gifts fusion_route_templates hooks plan_templates sinner_profiles theme_pack_gifts theme_packs],
    StarlightBot.RunsRepo => ~w[run_events run_logs]
  }

  setup do
    :ok = StarlightBot.TestDB.checkout()
  end

  for {repo, _} <- @expected do
    @repo repo
    @migrations_dir repo |> Module.split() |> List.last() |> Macro.underscore()

    test "#{inspect(repo)} applied every migration file" do
      path = Path.join([:code.priv_dir(:starlight_bot), @migrations_dir, "migrations"])
      files = Path.wildcard(Path.join(path, "*.exs"))
      assert files != [], "No migration files found in #{path}"

      {:ok, %{rows: [[count]]}} = Ecto.Adapters.SQL.query(@repo, "SELECT COUNT(*) FROM schema_migrations", [])
      assert count == length(files)
    end

    test "#{inspect(repo)} has its expected tables" do
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          @repo,
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name != 'schema_migrations' ORDER BY name",
          []
        )

      assert Enum.map(rows, fn [name] -> name end) == Enum.sort(@expected[@repo])
    end
  end
end
