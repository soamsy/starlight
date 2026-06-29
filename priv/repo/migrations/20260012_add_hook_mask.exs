defmodule StarlightBot.Repo.Migrations.AddHookMask do
  use Ecto.Migration

  def change do
    alter table(:hooks) do
      add :mask, :boolean, default: false, null: false
    end
  end
end
