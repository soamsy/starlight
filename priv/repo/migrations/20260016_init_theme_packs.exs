defmodule StarlightBot.Repo.Migrations.InitThemePacks do
  use Ecto.Migration

  def change do
    create table(:theme_packs, primary_key: false) do
      add :id, :string, primary_key: true
      add :name_en, :string, null: false
      add :name_ru, :string
      add :description_en, :string
      add :description_ru, :string
      add :normal_floors, :string
      add :hard_floors, :string
      add :tip, :string
      add :event_ids, :string
      add :image_path, :string
      add :hook_name, :string
      timestamps()
    end

    create table(:theme_pack_gifts, primary_key: false) do
      add :theme_pack_id, :string, primary_key: true
      add :gift_id, :string, primary_key: true
    end

    create table(:bosses, primary_key: false) do
      add :slug, :string, primary_key: true
      add :name_en, :string, null: false
      add :name_ru, :string
      add :image_path, :string
    end

    create table(:theme_pack_bosses, primary_key: false) do
      add :theme_pack_id, :string, primary_key: true
      add :boss_slug, :string, primary_key: true
    end

    create index(:theme_pack_gifts, [:gift_id])
    create index(:theme_pack_bosses, [:boss_slug])
  end
end
