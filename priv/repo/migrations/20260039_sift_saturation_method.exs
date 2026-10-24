defmodule StarlightBot.Repo.Migrations.SiftSaturationMethod do
  use Ecto.Migration

  def up do
    execute "UPDATE hooks SET match_method = 'sift_saturation' WHERE match_method = 'sift' AND feature_channel = 'saturation'"

    alter table(:hooks) do
      remove :feature_channel
    end
  end

  def down do
    alter table(:hooks) do
      add :feature_channel, :string
    end

    execute "UPDATE hooks SET match_method = 'sift', feature_channel = 'saturation' WHERE match_method = 'sift_saturation'"
  end
end
