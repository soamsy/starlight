defmodule StarlightBot.BaseRepo.Migrations.RemoveTeamTemplateHooks do
  use Ecto.Migration

  def change do
    alter table(:team_templates) do
      remove :hooks, :text, default: "[]", null: false
    end
  end
end
