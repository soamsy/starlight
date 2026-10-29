defmodule StarlightBot.Repo.Migrations.PlanTemplates do
  use Ecto.Migration

  def change do
    create table(:plan_templates) do
      add :kind, :string, null: false
      add :name, :string, null: false
      add :data, :text
      timestamps()
    end

    create unique_index(:plan_templates, [:kind, :name])
  end
end
