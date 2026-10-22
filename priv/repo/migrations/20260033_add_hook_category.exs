defmodule StarlightBot.Repo.Migrations.AddHookCategory do
  use Ecto.Migration

  def up do
    alter table(:hooks) do
      add :category, :string, null: false, default: "general"
    end

    flush()

    execute """
    UPDATE hooks SET category = CASE
      WHEN name LIKE 'sleevesearch\\_%' ESCAPE '\\' THEN 'sleevesearch'
      WHEN name LIKE 'sleeve\\_%' ESCAPE '\\' THEN 'sleeve'
      WHEN name LIKE 'locator\\_%' ESCAPE '\\' THEN 'locator'
      WHEN name LIKE 'team\\_select%' ESCAPE '\\' THEN 'general'
      WHEN name LIKE 'team\\_%\\_selected' ESCAPE '\\' THEN 'team_selected'
      WHEN name LIKE 'team\\_%' ESCAPE '\\' THEN 'team'
      ELSE 'general'
    END
    """

    create index(:hooks, [:category, :name])
  end

  def down do
    drop index(:hooks, [:category, :name])

    alter table(:hooks) do
      remove :category
    end
  end
end
