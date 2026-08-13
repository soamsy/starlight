defmodule StarlightBot.Navigation.Screens.Lux do
  use StarlightBot.Navigation.DSL

  screen :lux, identity: :lux_tab_exp do
    transition to: :home_drive, do: [key(:esc)]
  end

  screen :lux_exp, identity: all_of([:lux_exp_aligned_correctly, not_hook(:lux_right_arrow)]), refines: :lux do
    transition to: :lux_thread, do: [
      retry_until(:lux_thread_time_left, [click(:lux_tab_thread)]),
      branch([
        {:lux_left_arrow, [
          move_to(:lux_scroll),
          retry_until_arrived([scroll_down(30)], every: 600, tries: 10),
        ]}
      ])
    ]
    transition to: :team_select, do: [reclick_until_gone(:lux_exp_enter)]
  end

  screen :lux_thread, identity: all_of([:lux_thread_time_left, not_hook(:lux_left_arrow)]), refines: :lux do
    transition to: :lux_exp, do: [
      retry_until(:lux_exp_aligned_correctly, [click(:lux_tab_exp)]),
      branch([
        {:lux_right_arrow, [
          move_to(:lux_scroll),
          retry_until_arrived([scroll_up(30)], every: 600, tries: 10),
        ]}
      ])
    ]

    transition to: :team_select do
      [
        click(:lux_thread_enter),
        move_to(:lux_thread_confirm_popup_enter_third_hardest),
        retry_until(:lux_thread_confirm_popup_at_bottom, [scroll_down(10)], every: 300, tries: 5),
        click(:lux_thread_confirm_popup_enter_hardest),
        reclick_until_gone(:lux_thread_confirm_popup_enter_hardest, every: 100, tries: 2),
        branch([
          {:lux_thread_confirm_popup_enter_hardest, [reclick_until_arrived(:lux_thread_confirm_popup_enter_second_hardest)]},
          {:default, [wait_until_arrived()]}
        ])
      ]
    end
  end

  screen :lux_unknown, identity: nil, refines: :lux do
    transition to: :lux_exp do
      [
        click(:lux_tab_exp),
        move_to(:lux_scroll),
        retry_until_arrived([scroll_up(30)], every: 600, tries: 10),
      ]
    end

    transition to: :lux_thread do
      [
        click(:lux_tab_thread),
        move_to(:lux_scroll),
        retry_until_arrived([scroll_down(30)], every: 600, tries: 10),
      ]
    end
  end
end
