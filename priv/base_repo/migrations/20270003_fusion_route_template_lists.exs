defmodule StarlightBot.BaseRepo.Migrations.FusionRouteTemplateLists do
  use Ecto.Migration

  def up do
    execute ~S"""
    CREATE TABLE "fusion_route_templates_new" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "tier" INTEGER NOT NULL,
      "name" TEXT NOT NULL,
      "routes" TEXT NOT NULL,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
    )
    """

    execute ~S"""
    INSERT INTO fusion_route_templates_new (tier, name, routes, inserted_at, updated_at)
    SELECT tier, 'Default', routes, updated_at, updated_at FROM fusion_route_templates ORDER BY tier
    """

    execute ~S|DROP TABLE "fusion_route_templates"|
    execute ~S|ALTER TABLE "fusion_route_templates_new" RENAME TO "fusion_route_templates"|
    execute ~S|CREATE UNIQUE INDEX "fusion_route_templates_tier_name_index" ON "fusion_route_templates" ("tier", "name")|
  end

  def down, do: :ok
end
