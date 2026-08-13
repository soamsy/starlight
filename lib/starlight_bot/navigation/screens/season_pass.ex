defmodule StarlightBot.Navigation.Screens.SeasonPass do
  use StarlightBot.Navigation.DSL

  screen :season_pass, identity: :season_pass_missions do
    transition to: :season_pass_missions_tab, do: [reclick_until_arrived(:season_pass_missions)]
    transition to: :home_window, do: [key(:esc)]
  end

  screen :season_pass_missions_tab, identity: :season_pass_missions_tab, refines: :season_pass do
    transition to: :season_pass, do: [reclick_until_arrived(:season_pass_battle_pass)]
  end
end
