defmodule StarlightBot.BaseRepo.Migrations.InitBase do
  use Ecto.Migration

  def up do
    execute ~S"""
    CREATE TABLE "hooks" ("name" TEXT PRIMARY KEY, "region_x" INTEGER, "region_y" INTEGER, "region_w" INTEGER, "region_h" INTEGER, "click_x" INTEGER, "click_y" INTEGER, "click_w" INTEGER, "click_h" INTEGER, "match_method" TEXT DEFAULT 'gray' NOT NULL, "confidence" NUMERIC DEFAULT 0.85 NOT NULL, "notes" TEXT, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL, "scan_x" INTEGER, "scan_y" INTEGER, "scan_w" INTEGER, "scan_h" INTEGER, "mask" INTEGER DEFAULT false NOT NULL, "color_h" INTEGER, "color_s" INTEGER, "color_v" INTEGER, "min_cluster_size" INTEGER, "category" TEXT DEFAULT 'general' NOT NULL, "tol_h" INTEGER, "tol_s" INTEGER, "tol_v" INTEGER, "version" INTEGER DEFAULT 1 NOT NULL)
    """

    execute ~S"""
    CREATE INDEX "hooks_category_name_index" ON "hooks" ("category", "name")
    """

    execute ~S"""
    CREATE TABLE "ego_gifts" ("id" TEXT PRIMARY KEY, "name" TEXT NOT NULL, "sin" TEXT, "affinity" TEXT, "tier" INTEGER, "buying_cost" INTEGER, "selling_cost" INTEGER, "obtain_method" TEXT, "description" TEXT, "uptie2" TEXT, "uptie3" TEXT, "ingredients" TEXT, "original_id" INTEGER, "sort_id" INTEGER, "image_path" TEXT)
    """

    execute ~S"""
    CREATE INDEX "ego_gifts_affinity_index" ON "ego_gifts" ("affinity")
    """

    execute ~S"""
    CREATE INDEX "ego_gifts_sin_index" ON "ego_gifts" ("sin")
    """

    execute ~S"""
    CREATE TABLE "theme_packs" ("id" TEXT PRIMARY KEY, "name_en" TEXT NOT NULL, "name_ru" TEXT, "description_en" TEXT, "description_ru" TEXT, "normal_floors" TEXT, "hard_floors" TEXT, "tip" TEXT, "event_ids" TEXT, "image_path" TEXT, "hook_name" TEXT, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL, "search_hook_name" TEXT)
    """

    execute ~S"""
    CREATE TABLE "theme_pack_gifts" ("theme_pack_id" TEXT, "gift_id" TEXT, PRIMARY KEY ("theme_pack_id","gift_id"))
    """

    execute ~S"""
    CREATE INDEX "theme_pack_gifts_gift_id_index" ON "theme_pack_gifts" ("gift_id")
    """

    execute ~S"""
    CREATE TABLE "plan_templates" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "kind" TEXT NOT NULL, "name" TEXT NOT NULL, "data" TEXT, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL)
    """

    execute ~S"""
    CREATE UNIQUE INDEX "plan_templates_kind_name_index" ON "plan_templates" ("kind", "name")
    """

    execute ~S"""
    CREATE TABLE "sinner_profiles" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "sinner" TEXT, "locator_hook" TEXT, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL, "game_id" INTEGER, "name_en" TEXT, "released_on" TEXT)
    """

    execute ~S"""
    CREATE UNIQUE INDEX "sinner_profiles_name_index" ON "sinner_profiles" ("name")
    """

    execute ~S"""
    CREATE UNIQUE INDEX "sinner_profiles_game_id_index" ON "sinner_profiles" ("game_id")
    """

    execute ~S"""
    CREATE TABLE "fusion_route_templates" ("tier" INTEGER PRIMARY KEY, "routes" TEXT NOT NULL, "updated_at" TEXT NOT NULL)
    """
  end

  def down, do: :ok
end
