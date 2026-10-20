defmodule StarlightBot.Repo.Migrations.RunnerForms do
  use Ecto.Migration

  def up do
    create table(:runner_forms, primary_key: false) do
      add :runner, :string, primary_key: true
      add :params, :text, null: false
      add :updated_at, :utc_datetime, null: false
    end

    flush()

    %{rows: rows} = repo().query!("SELECT mirror_dungeon_action, luxcavation_action FROM scheduler_settings WHERE id = 1")
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    for [md, lux] <- rows, {runner, json} <- [{"mirror_dungeon", md}, {"luxcavation", lux}], json do
      params = json |> Jason.decode!() |> form_params()
      repo().query!("INSERT INTO runner_forms (runner, params, updated_at) VALUES (?, ?, ?)", [runner, Jason.encode!(params), now])
    end

    alter table(:scheduler_settings) do
      remove :mirror_dungeon_action
      remove :luxcavation_action
    end
  end

  def down do
    alter table(:scheduler_settings) do
      add :mirror_dungeon_action, :text
      add :luxcavation_action, :text
    end

    drop table(:runner_forms)
  end

  defp form_params(%{"kind" => "mirror_dungeon", "team_ids" => team_ids, "run_count" => run_count, "config" => config}) do
    %{
      "team_ids" => Enum.map(team_ids, &to_string/1),
      "start_index" => "0",
      "run_count" => to_string(run_count),
      "weekly_bonus" => to_string(config["weekly_bonus?"] == true),
      "collect_enkephalin" => to_string(config["collect_enkephalin?"] == true),
      "collect_xp" => to_string(config["collect_xp?"] == true),
      "capture_ego_gifts" => to_string(config["capture_ego_gifts?"] == true),
      "enkephalin_convert_count" => to_string(config["enkephalin_convert_count"] || 0)
    }
  end

  defp form_params(%{"kind" => "luxcavation", "args" => [team_id, exp_c, exp_r, thread_c, thread_r, xp?, enkephalin?, convert]}) do
    %{
      "team_id" => to_string(team_id),
      "exp_consecutive" => to_string(exp_c),
      "exp_repeats" => to_string(exp_r),
      "thread_consecutive" => to_string(thread_c),
      "thread_repeats" => to_string(thread_r),
      "collect_xp" => to_string(xp?),
      "collect_enkephalin" => to_string(enkephalin?),
      "enkephalin_convert_count" => to_string(convert)
    }
  end
end
