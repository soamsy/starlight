defmodule StarlightBot.Repo.Migrations.ReplaceGiftsWithEgoGifts do
  use Ecto.Migration

  def change do
    drop table(:gift_fusions)
    drop table(:gifts)

    create table(:ego_gifts, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :sin, :string
      add :affinity, :string
      add :tier, :integer
      add :buying_cost, :integer
      add :selling_cost, :integer
      add :obtain_method, :string
      add :description, :string
      add :uptie2, :string
      add :uptie3, :string
      add :ingredients, :string
      add :original_id, :integer
      add :sort_id, :integer
      add :image_path, :string
    end

    create index(:ego_gifts, [:affinity])
    create index(:ego_gifts, [:sin])
  end
end
