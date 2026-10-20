defmodule StarlightBot.Repo.Migrations.TeamHookLists do
  use Ecto.Migration

  def up do
    alter table(:teams) do
      add :hooks, :text, null: false, default: "[]"
    end

    flush()

    execute "UPDATE teams SET hooks = json_array(hook) WHERE hook IS NOT NULL AND hook != ''"

    alter table(:teams) do
      remove :hook
    end
  end

  def down do
    alter table(:teams) do
      add :hook, :string
    end

    flush()

    execute "UPDATE teams SET hook = json_extract(hooks, '$[0]')"

    alter table(:teams) do
      remove :hooks
    end
  end
end
