defmodule StarlightBot.Repo.Migrations.DropTeamTemplateColumns do
  use Ecto.Migration

  def up do
    flush()

    columns = "SELECT name FROM pragma_table_info('teams')" |> repo().query!() |> Map.fetch!(:rows) |> List.flatten()

    for column <- ["template", "base_template_id"], column in columns do
      repo().query!(~s|ALTER TABLE "teams" DROP COLUMN "#{column}"|)
    end

    repo().query!("DELETE FROM schema_migrations WHERE version = 20270039")
  end

  def down, do: :ok
end
