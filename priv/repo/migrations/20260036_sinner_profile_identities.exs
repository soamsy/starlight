defmodule StarlightBot.Repo.Migrations.SinnerProfileIdentities do
  use Ecto.Migration

  def change do
    alter table(:sinner_profiles) do
      add :game_id, :integer
      add :name_en, :string
      add :image_path, :string
    end

    create unique_index(:sinner_profiles, [:game_id])
  end
end
