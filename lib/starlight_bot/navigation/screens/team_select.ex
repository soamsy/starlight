defmodule StarlightBot.Navigation.Screens.TeamSelect do
  use StarlightBot.Navigation.DSL

  screen :team_select, identity: any_of([:team_selector, :team_selector_tall, :team_selector_gone]) do
    transition to: :exit_team_select, do: [key(:esc)]
    transition to: :battle do
      [
        sleep(50),
        premove(:battle_safe_click_spot),
        await(:to_battle, timeout: 1_000),
        retry_until(any_of([:loading_stage_1, :loading_stage_2]), [key(:enter)], every: 200, timeout: 15_000)
      ] ++ loading() ++ [await(:battle_settings, timeout: 5_000, premove: false)]
    end
  end

  screen :team_selector_md, identity: :team_selector_md, refines: :team_select do
    transition to: :exit_team_select, do: [key(:esc)]
    transition to: :grace do
      [
        retry_until_arrived([key(:enter)], every: 200, timeout: 10_000)
      ]
    end
  end

  screen :exit_team_select, identity: nil, catch_all: true do end
end
