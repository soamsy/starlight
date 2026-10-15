defmodule StarlightBot.Repo.Migrations.InitSinnerProfiles do
  use Ecto.Migration

  def change do
    create table(:sinner_profiles) do
      add :name, :string, null: false
      add :sinner, :string
      add :locator_hook, :string
      timestamps()
    end

    create unique_index(:sinner_profiles, [:name])
  end
end
