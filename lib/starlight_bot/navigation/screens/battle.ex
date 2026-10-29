defmodule StarlightBot.Navigation.Screens.Battle do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.PlaybookRunner
  alias StarlightBot.Navigation.Screens.Event

  @battle_kind_wait_ms 3_000

  screen :battle, identity: any_of([:battle_settings, :battle_turn]) do
    transition to: :battle_turn_or_over do
      wait_for_user_input_state()
    end

    transition to: :battle_settings_popup do
      [retry_until(:battle_settings_give_up, [click(:battle_settings_gear)], every: 1_000, tries: 3)]
    end
  end

  screen :battle_settings_popup, identity: :battle_settings_give_up, refines: :battle do
    transition to: :battle, do: [key(:esc), sleep(300)]
    transition to: :battle_given_up, do: [click(:battle_settings_give_up)] ++ loading()
    transition to: :battle_retried, do: [click(:battle_settings_retry)] ++ loading()
  end

  screen :battle_given_up, identity: nil, catch_all: true
  screen :battle_retried, identity: nil, catch_all: true

  screen :battle_defeat, identity: :battle_defeat_retry do
    transition to: :battle_retried, do: defeat_choice(:battle_defeat_retry)
    transition to: :battle_given_up, do: defeat_choice(:battle_defeat_to_stage_select)
  end

  screen :battle_turn, identity: :battle_turn, refines: :battle do
    transition to: :battle_playing do
      [
        branch(
          [
            {:battle_chain, [call(PlaybookRunner, :play_chain_turn), await_playing()]},
            {:battle_focused, [call(PlaybookRunner, :play_focused_turn), await_playing()]},
            {:default,
              [
                key(:p), sleep(100), key(:enter),
                retry_until_arrived(
                  [click(:battle_safe_click_spot), sleep(100), key(:p), sleep(100), key(:enter)],
                  tries: 3
                )
              ]}
          ],
          wait: @battle_kind_wait_ms
        )
      ]
    end
  end

  screen :battle_chain, identity: :battle_chain, refines: :battle_turn do
    transition to: :battle_playing do
      [call(PlaybookRunner, :play_chain_turn), await_playing()]
    end
  end

  screen :battle_focused, identity: :battle_focused, refines: :battle_turn do
    transition to: :battle_playing do
      [call(PlaybookRunner, :play_focused_turn), await_playing()]
    end
  end

  screen :battle_playing, identity: any_of([:battle_pause_button, :battle_playing_graph]), refines: :battle do
    transition to: :battle_turn_or_over do
      wait_for_user_input_state()
    end
  end

  screen :battle_turn_or_over, identity: nil, catch_all: true

  screen :battle_over_confirm, identity: :battle_over_black_confirm do
    transition to: :battle_turn_or_over, do: [reclick_until_gone(:battle_over_black_confirm)]
  end

  defp wait_for_user_input_state do
    [
      # Reflects how pause is sometimes completely hidden for special battle animations, like E.G.O skills.
      # So, wait for pause to disappear, wait for animation exit OR if pause appears again, repeat
      retry_until(any_of([:battle_turn, :loading_stage_1, :loading_stage_2, :battle_over_black_confirm, :battle_defeat_retry]), [
        branch([
          {:event, Event.play_out_steps()},
          {:default,
            [
              premove(:battle_safe_click_spot),
              wait_until(not_hook(any_of([:battle_pause_button, :battle_playing_graph])), timeout: 250_000),
              hold_mouse_during([
                wait_until(
                  any_of([:battle_turn, :loading_stage_1, :loading_stage_2, :battle_over_black_confirm, :battle_defeat_retry, :battle_pause_button, :battle_playing_graph, :event]),
                  timeout: 60_000
                )
              ]),
            ]}
        ])
      ], tries: 15),
      branch(turn_boundary_clauses())
    ]
  end

  defp await_playing do
    wait_until(any_of([:battle_pause_button, :battle_playing_graph]), timeout: 8_000, every: 200)
  end

  defp hold_mouse_during(steps), do: ensure([mouse_down() | steps], [mouse_up()])

  defp turn_boundary_clauses do
    [
      {:battle_turn, [sleep(100), wait_until(not_hook(:turn_opener)), sleep(150)]},
      {:loading_stage_1, loading() ++ after_loading()},
      {:loading_stage_2, loading() ++ after_loading()},
      confirm_battle_clause(),
      {:battle_defeat_retry, []},
      {:default, [sleep(100)]}
    ]
  end

  defp after_loading do
    [call(PlaybookRunner, :new_battle), branch([confirm_battle_clause(), {:default, []}])]
  end

  defp defeat_choice(choice) do
    [
      click(choice)
    ] ++ confirm_enter(:battle_defeat_confirm) ++ [
      premove(:battle_safe_click_spot)
    ] ++ loading()
  end

  defp confirm_battle_clause do
    {:battle_over_black_confirm, [reclick_until_gone(:battle_over_black_confirm)]}
  end
end
