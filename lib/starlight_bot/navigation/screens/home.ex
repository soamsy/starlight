defmodule StarlightBot.Navigation.Screens.Home do
  use StarlightBot.Navigation.DSL

  screen :home, identity: :home_lunacy do
    transition to: :charge_enkephalin, do: [reclick_until_arrived(:home_lunacy, every: 1500, timeout: 5000)]
  end

  screen :home_window, identity: :home_window_selected, refines: :home do
    transition to: :home_drive, do: [reclick_until_arrived(:home_drive_unselected)]
    transition to: :home_sinners, do: [reclick_until_arrived(:home_sinners_unselected)]
    transition to: :home_theater, do: [reclick_until_arrived(:home_theater_unselected)]
    transition to: :home_extract, do: [reclick_until_arrived(:home_extract_unselected)]
    transition to: :home_dispense, do: [reclick_until_arrived(:home_dispense_unselected)]
    transition to: :season_pass, do: [reclick_until_arrived(:home_window_season_pass)]
  end

  screen :home_drive, identity: :home_drive_selected, refines: :home do
    transition to: :home_window, do: [reclick_until_arrived(:home_window_unselected)]
    transition to: :home_sinners, do: [reclick_until_arrived(:home_sinners_unselected)]
    transition to: :home_theater, do: [reclick_until_arrived(:home_theater_unselected)]
    transition to: :home_extract, do: [reclick_until_arrived(:home_extract_unselected)]
    transition to: :home_dispense, do: [reclick_until_arrived(:home_dispense_unselected)]
    transition to: :lux, do: [reclick_until_arrived(:home_drive_lux)]
    transition to: :md_door, do: [reclick_until_arrived(:home_drive_mirror_dungeon)]
  end

  screen :home_sinners, identity: :home_sinners_selected, refines: :home do
    transition to: :home_window, do: [reclick_until_arrived(:home_window_unselected)]
    transition to: :home_drive, do: [reclick_until_arrived(:home_drive_unselected)]
    transition to: :home_theater, do: [reclick_until_arrived(:home_theater_unselected)]
    transition to: :home_extract, do: [reclick_until_arrived(:home_extract_unselected)]
    transition to: :home_dispense, do: [reclick_until_arrived(:home_dispense_unselected)]
  end

  screen :home_theater, identity: :home_theater_selected, refines: :home do
    transition to: :home_window, do: [reclick_until_arrived(:home_window_unselected)]
    transition to: :home_drive, do: [reclick_until_arrived(:home_drive_unselected)]
    transition to: :home_sinners, do: [reclick_until_arrived(:home_sinners_unselected)]
    transition to: :home_extract, do: [reclick_until_arrived(:home_extract_unselected)]
    transition to: :home_dispense, do: [reclick_until_arrived(:home_dispense_unselected)]
  end

  screen :home_extract, identity: :home_extract_selected, refines: :home do
    transition to: :home_window, do: [reclick_until_arrived(:home_window_unselected)]
    transition to: :home_drive, do: [reclick_until_arrived(:home_drive_unselected)]
    transition to: :home_sinners, do: [reclick_until_arrived(:home_sinners_unselected)]
    transition to: :home_theater, do: [reclick_until_arrived(:home_theater_unselected)]
    transition to: :home_dispense, do: [reclick_until_arrived(:home_dispense_unselected)]
  end

  screen :home_dispense, identity: :home_dispense_selected, refines: :home do
    transition to: :home_window, do: [reclick_until_arrived(:home_window_unselected)]
    transition to: :home_drive, do: [reclick_until_arrived(:home_drive_unselected)]
    transition to: :home_sinners, do: [reclick_until_arrived(:home_sinners_unselected)]
    transition to: :home_theater, do: [reclick_until_arrived(:home_theater_unselected)]
    transition to: :home_extract, do: [reclick_until_arrived(:home_extract_unselected)]
  end

  screen :home_unknown, identity: nil, refines: :home do
    transition to: :home_window do
      [
        branch([
          home_window_selected: [],
          default: [reclick_until_arrived(:home_window_unselected)]
        ])
      ]
    end

    transition to: :home_drive do
      [
        branch([
          home_drive_selected: [],
          default: [reclick_until_arrived(:home_drive_unselected)]
        ])
      ]
    end

    transition to: :home_sinners do
      [
        branch([
          home_sinners_selected: [],
          default: [reclick_until_arrived(:home_sinners_unselected)]
        ])
      ]
    end

    transition to: :home_theater do
      [
        branch([
          home_theater_selected: [],
          default: [reclick_until_arrived(:home_theater_unselected)]
        ])
      ]
    end

    transition to: :home_extract do
      [
        branch([
          home_extract_selected: [],
          default: [reclick_until_arrived(:home_extract_unselected)]
        ])
      ]
    end

    transition to: :home_dispense do
      [
        branch([
          home_dispense_selected: [],
          default: [reclick_until_arrived(:home_dispense_unselected)]
        ])
      ]
    end
  end
end
