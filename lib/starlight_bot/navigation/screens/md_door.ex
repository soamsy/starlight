defmodule StarlightBot.Navigation.Screens.MdDoor do
  use StarlightBot.Navigation.DSL

  screen :md_door, identity: :mirror_dungeon_door do end
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
    transition to: :team_select, do: [reclick_until_gone(:mirror_dungeon_door_popup_white_enter), wait_until_arrived(timeout: 4_800)]
  end
  screen :md_door_session_expired, identity: :mirror_dungeon_door_session_expired_confirm, refines: :md_door do
    transition to: :exploration_reward, do: [reclick_until_gone(:mirror_dungeon_door_session_expired_confirm)]
  end
  screen :md_door_unknown, identity: nil, refines: :md_door, settle: false do
    transition to: :home_drive, do: [key(:esc)]
    transition to: :md_door_enter do
      [
        move_to(:mirror_dungeon_door_enter),
        branch([
          {not_hook(:mirror_dungeon_door_previous_run), [
            retry_until(
              any_of([:mirror_dungeon_door_popup_white_enter, :team_selector_md]),
              [click(:mirror_dungeon_door_enter)],
              every: 200,
              timeout: 8_000
            ),
            retry_until_gone(:mirror_dungeon_door_popup_white_enter, [key(:enter)], every: 400, timeout: 4_000),
            wait_until(:team_selector_md, every: 400, timeout: 10_000),
          ]},
          {:default, [retry_until(
            any_of([
              :mirror_dungeon_door_popup_white_enter,
              :mirror_dungeon_door_progress,
              :mirror_dungeon_door_forfeit,
              :mirror_dungeon_door_session_expired_confirm,
              :exploration_reward,
            ]),
            [click(:mirror_dungeon_door_enter)],
            every: 600,
            tries: 10
          )]}
        ]),
      ]
    end
  end

  screen :md_door_enter, identity: nil, catch_all: true
  screen :md_door_progress_resume, identity: nil, catch_all: true

end
