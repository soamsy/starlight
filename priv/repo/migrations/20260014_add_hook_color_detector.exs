defmodule StarlightBot.Repo.Migrations.AddHookColorDetector do
  use Ecto.Migration

  def change do
    alter table(:hooks) do
      add :color_h, :integer
      add :color_s, :integer
      add :color_v, :integer
      add :min_cluster_size, :integer
    end
  end
end
