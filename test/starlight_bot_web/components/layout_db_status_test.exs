defmodule StarlightBotWeb.LayoutDbStatusTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias StarlightBot.Scheduler.Overview
  alias StarlightBotWeb.Layouts

  @problem %{
    name: "user",
    label: "Plans and settings",
    messages: ["file is not a database"],
    backup: "/tmp/backups/user-20261120T090000.db",
    backup_at: ~N[2026-11-20 09:00:00],
    can_fresh?: true,
    pending: false
  }

  setup do
    :ok = StarlightBot.TestDB.checkout()
  end

  defp assigns(db_problems) do
    %{
      flash: %{},
      inner_content: "",
      page: :teams,
      tab: nil,
      run_kind: nil,
      run_timer_key: nil,
      run_timer_ms: 0,
      run_live: false,
      team_nav: nil,
      latest_log: nil,
      scheduler_overview: Overview.build(),
      game_window_rect: {0, 0, 1920, 1080},
      game_window_busy: nil,
      game_launch_label: nil,
      game_launcher_label: nil,
      game_launcher_missing: [],
      game_update_pending: false,
      cursor_speed: 1.0,
      hesitation_mult: 1.0,
      settings_open: false,
      db_problems: db_problems,
      input_error: nil
    }
  end

  test "the layout renders the window status without a damaged database" do
    html = render_component(&Layouts.app/1, assigns([]))

    assert html =~ "Limbus window is the right size"
    refute html =~ "file looks damaged"
  end

  test "the layout shows a damaged database in the status menu" do
    html = render_component(&Layouts.app/1, assigns([@problem]))

    assert html =~ "Plans and settings file looks damaged"
    assert html =~ "Restore backup on next start"
    assert html =~ "Start fresh on next start"
    assert html =~ "file is not a database"
  end

  test "a pending repair asks for a restart instead of offering the buttons" do
    html = render_component(&Layouts.app/1, assigns([%{@problem | pending: true}]))

    assert html =~ "Restart the app to finish the repair"
    refute html =~ "Restore backup on next start"
  end

  test "a live run shows the activity icon and a run timer keyed to the run" do
    live = Map.merge(assigns([]), %{run_live: true, run_timer_key: {1_700_000_000, true}, run_timer_ms: 65_000})
    html = render_component(&Layouts.app/1, live)

    assert html =~ ~s(id="run-timer-1700000000-true")
    assert html =~ ~s(data-elapsed="65000")
    assert html =~ ~s(data-running="true")
    assert html =~ "lucide-activity"
  end

  test "an idle nav has no run timer" do
    html = render_component(&Layouts.app/1, assigns([]))

    refute html =~ "run-timer"
  end
end
