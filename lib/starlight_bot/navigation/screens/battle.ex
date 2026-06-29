defmodule StarlightBot.Navigation.Screens.Battle do
  use StarlightBot.Navigation.DSL

  screen :battle, identity: :battle_settings do
    transition to: :battle_turn_or_over do
      wait_for_user_input_state()
    end
  end

  screen :battle_turn, identity: :battle_turn, refines: :battle do
    transition to: :battle_playing do
      [key(:p), sleep(100), key(:enter)]
    end
  end

  screen :battle_chain, identity: :battle_chain, refines: :battle_turn do
  end

  screen :battle_focused, identity: :battle_focused, refines: :battle_turn do
  end

  screen :battle_playing, identity: :battle_pause_button, refines: :battle do
    transition to: :battle_turn_or_over do
      wait_for_user_input_state()
    end
  end

  screen :battle_turn_or_over, identity: nil, catch_all: true

  defp wait_for_user_input_state do
    [
      # Reflects how pause is sometimes completely hidden for special battle animations, like E.G.O skills.
      # So, wait for pause to disappear, wait for animation exit OR if pause appears again, repeat
      retry_until([:battle_turn, :loading_stage_1, :battle_over_black_confirm], [
        wait_until(not_hook(:battle_pause_button), timeout: 150_000),
        wait_until([:battle_turn, :loading_stage_1, :battle_over_black_confirm, :battle_pause_button], timeout: 15_000),
      ], tries: 15),
      branch(turn_boundary_clauses())
    ]
  end

  defp turn_boundary_clauses do
    [
      {:battle_turn, [sleep(80), wait_until(not_hook(:turn_opener))]},
      {:loading_stage_1, loading() ++ after_loading()},
      confirm_battle_clause(),
      {:default, [sleep(1_000)]}
    ]
  end

  defp after_loading do
    [branch([confirm_battle_clause(), {:default, []}])]
  end

  defp confirm_battle_clause do
    {:battle_over_black_confirm, [reclick_until_gone(:battle_over_black_confirm)]}
  end
end
