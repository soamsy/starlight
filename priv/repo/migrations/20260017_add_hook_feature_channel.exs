defmodule StarlightBot.Repo.Migrations.AddHookFeatureChannel do
  use Ecto.Migration

  def change do
    alter table(:hooks) do
      add :feature_channel, :string
    end
  end
end
