defmodule StarlightBot.Repo.Migrations.TeamPosition do
  use Ecto.Migration

  def up do
    alter table(:teams) do
      add :position, :integer, null: false, default: 0
    end

    execute """
    UPDATE teams SET position = (
      SELECT COUNT(*) FROM teams other WHERE other.name < teams.name
    )
    """
  end

  def down do
    alter table(:teams) do
      remove :position
    end
  end
end
