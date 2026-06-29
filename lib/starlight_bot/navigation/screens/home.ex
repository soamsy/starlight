defmodule StarlightBot.Navigation.Screens.Home do
  use StarlightBot.Navigation.DSL

  screen :home, identity: :home_lunacy do
    transition to: :charge_enkephalin, do: [reclick_until_arrived(:home_lunacy)]
  end

  screen :home_window, identity: :home_window_selected, refines: :home do
    transition to: :home_drive, do: [reclick_until_arrived(:home_drive_unselected)]
  end

  screen :home_drive, identity: :home_drive_selected, refines: :home do
    transition to: :home_window, do: [reclick_until_arrived(:home_window_unselected)]
    transition to: :lux, do: [sleep(200), reclick_until_arrived(:home_drive_lux)]
    transition to: :md_door, do: [sleep(200), reclick_until_arrived(:home_drive_mirror_dungeon)]
  end

  screen :home_unknown, identity: nil, refines: :home do
    transition to: :home_drive do
      [
        branch([
          home_drive_selected: [],
          default: [reclick_until_arrived(:home_drive_unselected)]
        ])
      ]
    end

    transition to: :home_window do
      [
        branch([
          home_window_selected: [],
          default: [reclick_until_arrived(:home_window_unselected)]
        ])
      ]
    end
  end
end
