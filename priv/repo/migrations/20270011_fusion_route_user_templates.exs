defmodule StarlightBot.Repo.Migrations.FusionRouteUserTemplates do
  use Ecto.Migration

  def up do
    execute ~S"""
    CREATE TABLE "fusion_route_user_templates" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "tier" INTEGER NOT NULL,
      "name" TEXT NOT NULL,
      "routes" TEXT NOT NULL,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
    )
    """

    execute ~S"""
    INSERT INTO fusion_route_user_templates (tier, name, routes, inserted_at, updated_at)
    SELECT tier, 'My default', routes, updated_at, updated_at FROM fusion_route_defaults ORDER BY tier
    """

    execute ~S|CREATE UNIQUE INDEX "fusion_route_user_templates_tier_name_index" ON "fusion_route_user_templates" ("tier", "name")|
    execute ~S|DROP TABLE "fusion_route_defaults"|
  end

  def down, do: :ok
end
