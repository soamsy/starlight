defmodule StarlightBot.Repo.Migrations.InitUser do
  use Ecto.Migration

  def up do
    execute ~S"""
    CREATE TABLE "teams" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "gift_plan_id" INTEGER, "battle_plan_id" INTEGER, "pack_plan_id" INTEGER, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL, "hooks" TEXT DEFAULT '[]' NOT NULL, "position" INTEGER DEFAULT 0 NOT NULL)
    """

    execute ~S"""
    CREATE UNIQUE INDEX "teams_name_index" ON "teams" ("name")
    """

    execute ~S"""
    CREATE TABLE "battle_plans" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "data" TEXT, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL)
    """

    execute ~S"""
    CREATE UNIQUE INDEX "battle_plans_name_index" ON "battle_plans" ("name")
    """

    execute ~S"""
    CREATE TABLE "pack_plans" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "data" TEXT, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL)
    """

    execute ~S"""
    CREATE UNIQUE INDEX "pack_plans_name_index" ON "pack_plans" ("name")
    """

    execute ~S"""
    CREATE TABLE "gift_plans" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "data" TEXT, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL)
    """

    execute ~S"""
    CREATE UNIQUE INDEX "gift_plans_name_index" ON "gift_plans" ("name")
    """

    execute ~S"""
    CREATE TABLE "scheduler_settings" ("id" INTEGER PRIMARY KEY, "enabled" INTEGER DEFAULT false NOT NULL, "runner" TEXT DEFAULT 'mirror_dungeon' NOT NULL, "window_start" TEXT DEFAULT '09:00' NOT NULL, "window_end" TEXT DEFAULT '12:00' NOT NULL, "launch_mode" TEXT DEFAULT 'steam' NOT NULL, "steam_app_id" TEXT DEFAULT '1973530' NOT NULL, "exe_path" TEXT, "launch_timeout_s" INTEGER DEFAULT 600 NOT NULL, "last_fired_on" TEXT, "updated_at" TEXT NOT NULL)
    """

    execute ~S"""
    CREATE TABLE "runner_forms" ("runner" TEXT PRIMARY KEY, "params" TEXT NOT NULL, "updated_at" TEXT NOT NULL)
    """

    execute ~S"""
    CREATE TABLE "fusion_route_defaults" ("tier" INTEGER PRIMARY KEY, "routes" TEXT NOT NULL, "updated_at" TEXT NOT NULL)
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
    CREATE TABLE "hook_overrides" ("name" TEXT PRIMARY KEY, "region_x" INTEGER, "region_y" INTEGER, "region_w" INTEGER, "region_h" INTEGER, "click_x" INTEGER, "click_y" INTEGER, "click_w" INTEGER, "click_h" INTEGER, "match_method" TEXT DEFAULT 'gray' NOT NULL, "confidence" NUMERIC DEFAULT 0.85 NOT NULL, "notes" TEXT, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL, "scan_x" INTEGER, "scan_y" INTEGER, "scan_w" INTEGER, "scan_h" INTEGER, "mask" INTEGER DEFAULT false NOT NULL, "color_h" INTEGER, "color_s" INTEGER, "color_v" INTEGER, "min_cluster_size" INTEGER, "category" TEXT DEFAULT 'general' NOT NULL, "tol_h" INTEGER, "tol_s" INTEGER, "tol_v" INTEGER, "base_version" INTEGER)
    """

    execute ~S"""
    CREATE INDEX "hook_overrides_category_name_index" ON "hook_overrides" ("category", "name")
    """

    execute ~S"""
    INSERT INTO scheduler_settings (id, updated_at) VALUES (1, strftime('%Y-%m-%dT%H:%M:%S', 'now'))
    """
  end

  def down, do: :ok
end
