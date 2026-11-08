defmodule StarlightBot.BaseRepo.Migrations.ThemePackNodeCount do
  use Ecto.Migration

  def up do
    execute ~S|ALTER TABLE "theme_packs" ADD COLUMN "node_count" INTEGER|
    execute ~S|UPDATE "theme_packs" SET "description_en" = REPLACE("description_en", 'Lenght', 'Length') WHERE "description_en" LIKE '%Lenght%'|
    flush()

    %{rows: rows} = repo().query!(~S|SELECT "id", "description_en" FROM "theme_packs" WHERE "description_en" IS NOT NULL|)

    for [id, description] <- rows, [_, count] <- [Regex.run(~r/Length:\s*(\d+)\s*nodes/i, description)] do
      repo().query!(~S|UPDATE "theme_packs" SET "node_count" = ?1 WHERE "id" = ?2|, [String.to_integer(count), id])
    end
  end

  def down, do: :ok
end
