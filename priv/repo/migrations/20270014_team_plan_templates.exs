defmodule StarlightBot.Repo.Migrations.TeamPlanTemplates do
  use Ecto.Migration

  def change do
    alter table(:teams) do
      add :gift_template_id, :integer
      add :battle_template_id, :integer
      add :pack_template_id, :integer
    end
  end
end
