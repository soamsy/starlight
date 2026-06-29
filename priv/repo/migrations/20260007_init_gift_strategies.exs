defmodule StarlightBot.Repo.Migrations.InitGiftStrategies do
  use Ecto.Migration

  def change do
    create table(:gift_strategies) do
      add :name,                   :string,  null: false
      add :affinity,               :string
      add :priority_fusions,       :string   # JSON array of gift names
      add :desired_items,          :string   # JSON array of gift names
      add :max_purchases,          :integer, default: 4
      add :max_normal_refreshes,   :integer, default: 1
      add :max_keyword_refreshes,  :integer, default: 0
      add :uptie_targets,          :string   # JSON array of gift names
      add :sell_threshold,         :integer, default: 0
      add :heal_threshold,         :float,   default: 0.0
      add :gift_values,            :string   # JSON map gift_name => integer
      add :skip_shop_threshold,    :integer
      timestamps()
    end

    create unique_index(:gift_strategies, [:name])
  end
end
