defmodule StarlightBot.BaseRepo.Migrations.DropTeamTemplates do
  use Ecto.Migration

  def up do
    execute(~S|DROP TABLE IF EXISTS "team_templates"|)
    execute(~S|DELETE FROM schema_migrations WHERE version = 20270040|)
  end

  def down, do: :ok
end
