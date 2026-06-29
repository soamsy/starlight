defmodule StarlightBot.Repo.Migrations.RedesignTeamConfig do
  use Ecto.Migration

  def change do
    drop table(:teams)
    drop table(:gift_strategies)
    drop table(:pack_strategies)

    create table(:gift_strategies) do
      add :name, :string, null: false
      add :data, :string  # versioned JSON, e.g. {version, type: "predefined", affinity: "burn"}
      timestamps()
    end

    create unique_index(:gift_strategies, [:name])

    create table(:battle_strategies) do
      add :name, :string, null: false
      add :data, :string  # versioned JSON, e.g. {version, type: "win_rate"}
      timestamps()
    end

    create unique_index(:battle_strategies, [:name])

    create table(:theme_pack_plans) do
      add :name, :string, null: false
      add :data, :string  # versioned JSON, e.g. {version, type: "random"}
      timestamps()
    end

    create unique_index(:theme_pack_plans, [:name])

    create table(:teams) do
      add :name,               :string, null: false
      add :hook,                :string  # team_<type> hook name used in team select
      add :sinner_order,        :string  # JSON array of sinner keys, in pick order
      add :gift_strategy_id,    :integer
      add :battle_strategy_id,  :integer
      add :theme_pack_plan_id,  :integer
      timestamps()
    end

    create unique_index(:teams, [:name])
  end
end
