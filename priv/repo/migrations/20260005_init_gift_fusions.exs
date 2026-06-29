defmodule StarlightBot.Repo.Migrations.InitGiftFusions do
  use Ecto.Migration

  def change do
    create table(:gift_fusions) do
      add :output_gift,      :string,  null: false
      add :ingredient_gifts, :string,  null: false  # JSON [name]
      add :is_auto,          :boolean, null: false, default: false
      add :notes,            :string
      timestamps()
    end

    create index(:gift_fusions, [:output_gift])
  end
end
