defmodule StarlightBot.Repo.Migrations.AddHookScanRegion do
  use Ecto.Migration

  def change do
    alter table(:hooks) do
      add :scan_x, :integer
      add :scan_y, :integer
      add :scan_w, :integer
      add :scan_h, :integer
    end
  end
end
