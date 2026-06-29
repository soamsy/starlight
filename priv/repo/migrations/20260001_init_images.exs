defmodule StarlightBot.Repo.Migrations.InitImages do
  use Ecto.Migration

  def change do
    create table(:images) do
      add :data, :binary, null: false
      timestamps()
    end
  end
end
