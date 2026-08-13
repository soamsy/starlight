defmodule StarlightBot.Navigation.Screens.TeamSelect do
  use StarlightBot.Navigation.DSL

  screen :team_select, identity: any_of([:team_selector, :team_selector_tall, :team_selector_gone]) do
    transition to: :exit_team_select, do: [key(:esc)]
    transition to: :battle do
      [reclick_until_gone(:to_battle)] ++ loading()
    end
  end

  screen :team_selector_md, identity: :team_selector_md, refines: :team_select do
    transition to: :exit_team_select, do: [key(:esc)]
    transition to: :grace do
      [
        click(:team_selector_md),
        await_any([:team_select_popup_white_enter, :connecting, :grace_available], timeout: 3_000),
        branch([
          {:grace_available, []},
          {:team_select_popup_white_enter,
           [reclick_until_gone(:team_select_popup_white_enter)] ++
             await_then_gone(:connecting, appear_timeout: 3_000)},
          {:default, await_then_gone(:connecting, appear_timeout: 3_000)}
        ])
      ]
    end
  end

  screen :exit_team_select, identity: nil, catch_all: true do end
end
