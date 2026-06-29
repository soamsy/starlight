defmodule StarlightBot.Repo.Migrations.InitPackStrategies do
  use Ecto.Migration

  def change do
    create table(:pack_strategies) do
      add :name,          :string,  null: false
      add :floor_rules,   :string   # JSON %{floor_number => [PackRule]}
      add :max_refreshes, :integer, default: 3
      timestamps()
    end

    create unique_index(:pack_strategies, [:name])
  end
end
