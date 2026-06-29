defmodule StarlightBot.Repo.Migrations.InitTeams do
  use Ecto.Migration

  def change do
    create table(:teams) do
      add :name,                :string,  null: false
      add :label_keyword,       :string
      add :sinner_order,        :string   # JSON array of sinner name strings
      add :affinity,            :string
      add :difficulty,          :string,  default: "normal"
      add :extreme_mode,        :boolean, default: false
      add :gift_strategy_id,    :integer
      add :pack_strategy_id,    :integer
      add :battle_strategy,     :string   # JSON {mode, ego_priority}
      add :card_priority,       :string   # JSON array
      add :starlight_buffs,     :string   # JSON array of buff indices
      add :node_cost_overrides, :string   # JSON map node_type => cost_offset
      add :retry_stuck_battles, :boolean, default: true
      timestamps()
    end

    create unique_index(:teams, [:name])
  end
end
