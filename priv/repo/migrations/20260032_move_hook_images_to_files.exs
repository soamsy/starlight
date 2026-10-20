defmodule StarlightBot.Repo.Migrations.MoveHookImagesToFiles do
  use Ecto.Migration

  def change do
    alter table(:hooks) do
      remove :image, :binary
    end
  end
end
