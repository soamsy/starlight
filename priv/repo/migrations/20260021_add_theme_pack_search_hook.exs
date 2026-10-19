defmodule StarlightBot.Repo.Migrations.AddThemePackSearchHook do
  use Ecto.Migration

  def change do
    alter table(:theme_packs) do
      add :search_hook_name, :string
    end
  end
end
