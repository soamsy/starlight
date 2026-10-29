defmodule StarlightBot.Repo.Migrations.HsvRangeMethod do
  use Ecto.Migration

  def up do
    alter table(:hooks) do
      add :tol_h, :integer
      add :tol_s, :integer
      add :tol_v, :integer
    end

    flush()

    slack = "CAST(ROUND((1.0 - confidence) * 30) AS INTEGER)"

    execute "UPDATE hooks SET tol_h = #{slack}, tol_s = #{slack}, tol_v = #{slack} WHERE match_method = 'color_detector'"
    execute "UPDATE hooks SET tol_h = 90, tol_s = 255, tol_v = #{slack} WHERE match_method = 'value_detector'"
    execute "UPDATE hooks SET tol_h = 90, tol_s = #{slack}, tol_v = 255 WHERE match_method = 'saturation_detector'"

    execute "UPDATE hooks SET match_method = 'hsv_range' WHERE match_method IN ('color_detector', 'value_detector', 'saturation_detector')"
  end

  def down do
    execute "UPDATE hooks SET match_method = 'color_detector' WHERE match_method = 'hsv_range'"

    alter table(:hooks) do
      remove :tol_h
      remove :tol_s
      remove :tol_v
    end
  end
end
