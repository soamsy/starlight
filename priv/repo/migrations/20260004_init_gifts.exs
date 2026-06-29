defmodule StarlightBot.Repo.Migrations.InitGifts do
  use Ecto.Migration

  def change do
    create table(:gifts, primary_key: false) do
      add :id,         :integer, primary_key: true
      add :name,       :string
      add :image_id,   references(:images)
      add :tier,       :integer, null: false
      add :affinity,   :string
      add :buy_cost,   :integer
      add :sell_cost,  :integer
      add :uptie_cost, :integer
      add :notes,      :string
      timestamps()
    end

    create index(:gifts, [:affinity])
    create index(:gifts, [:tier])
  end
end
