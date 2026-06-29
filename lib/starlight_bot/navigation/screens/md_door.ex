defmodule StarlightBot.Navigation.Screens.MdDoor do
  use StarlightBot.Navigation.DSL

  screen :md_door, identity: :mirror_dungeon_door_enter do end
  screen :md_door_forfeit, identity: :mirror_dungeon_door_forfeit, refines: :md_door do
    transition to: :md_door, do: [key(:esc)]
    transition to: :exploration_reward, do: [reclick_until_gone(:mirror_dungeon_door_forfeit)]
  end
  screen :md_door_progress, identity: :mirror_dungeon_door_progress, refines: :md_door do
    transition to: :md_door, do: [key(:esc)]
    transition to: :md_door_progress_resume, do: [reclick_until_gone(:mirror_dungeon_door_progress_resume)]
    transition to: :md_door_forfeit, do: [reclick_until_gone(:mirror_dungeon_door_progress_halt)]
  end
  screen :md_door_enter_popup, identity: :mirror_dungeon_door_popup_white_enter, refines: :md_door do
    transition to: :md_door, do: [key(:esc)]
    transition to: :team_select, do: [reclick_until_gone(:mirror_dungeon_door_popup_white_enter)]
  end
  screen :md_door_unknown, identity: nil, refines: :md_door do
    transition to: :home_drive, do: [key(:esc)]
    transition to: :md_door_enter do
      [
        click(:mirror_dungeon_door_enter),
        await_any([
          :mirror_dungeon_door_popup_white_enter,
          :mirror_dungeon_door_progress,
          :mirror_dungeon_door_forfeit,
          :exploration_reward,
        ]),
      ]
    end
  end

  screen :md_door_enter, identity: nil, catch_all: true
  screen :md_door_progress_resume, identity: nil, catch_all: true

end
