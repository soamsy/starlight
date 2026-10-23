defmodule StarlightBot.Navigation.Screens.MdDoor do
  use StarlightBot.Navigation.DSL

  @enter_arm_or_open_ms 1_500
  @enter_unlock_gap_ms 100
  @enter_results [
    :mirror_dungeon_door_popup_white_enter,
    :mirror_dungeon_door_progress,
    :mirror_dungeon_door_forfeit,
    :mirror_dungeon_door_session_expired_confirm,
    :exploration_reward,
    :team_selector_md
  ]

  screen :md_door, identity: :mirror_dungeon_door do end
  screen :md_door_forfeit, identity: :mirror_dungeon_door_forfeit, refines: :md_door do
    transition to: :md_door, do: [key(:esc)]
    transition to: :exploration_reward, do: [reclick_until_gone(:mirror_dungeon_door_forfeit)]
  end
  screen :md_door_progress, identity: :mirror_dungeon_door_progress, refines: :md_door do
    transition to: :md_door, do: [key(:esc)]
    transition to: :md_door_progress_resume, do: confirm(:mirror_dungeon_door_progress_resume)
    transition to: :md_door_forfeit, do: confirm(:mirror_dungeon_door_progress_halt)
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
          mirror_dungeon_door_previous_run: [],
          default: [
            click(:mirror_dungeon_door_enter),
            sleep(@enter_unlock_gap_ms),
            click(:mirror_dungeon_door_enter),
            branch([{any_of(@enter_results), []}], wait: @enter_arm_or_open_ms)
          ]
        ]),
        retry_until(
          any_of(@enter_results),
          [click(:mirror_dungeon_door_enter)],
          every: @enter_arm_or_open_ms,
          tries: 6
        ),
      ]
    end
  end

  screen :md_door_enter, identity: nil, catch_all: true
  screen :md_door_progress_resume, identity: nil, catch_all: true

end
