defmodule StarlightBot.Navigation.Screens.Event do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.EventAdvantage
  alias StarlightBot.Ctx
  alias StarlightBot.Input.Mouse
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.Vision.{HookRegistry, Matcher}

  @gift_battle_min_gap 100

  screen :event, identity: :event do
    transition to: :event_over, do: play_out_steps()
  end

  screen :event_over, identity: nil, catch_all: true

  def play_out_steps do
    [
      retry_until(
        not_hook(:event),
        [
          branch([
            {:event_proceed, [reclick_until_gone(:event_proceed, every: 80)]},
            {:event_continue, [reclick_until_gone(:event_continue, every: 80)]},
            {:event_skip, [retry_until_gone(:event_skip, [key(:space)], every: 80), key(:space), sleep(40), key(:space)]},
            {:event_commence, [reclick_until_gone(:event_commence, every: 80)]},
            {:event_advantage_none_selected,
              [
                premove(:event_sinner_select),
                retry_until(
                  not_hook(:event_advantage_none_selected),
                  [custom(&EventAdvantage.select_best_sinner/2)],
                  every: 300,
                  tries: 20
                )
              ] ++ confirm(:event_commence, timeout: 1000, every: 80)},
            {:event_choices,
              [
                branch([
                  {:event_chicken_1, [click(:event_choice_0), sleep(300)]},
                  {:event_chicken_2, [click(:event_choice_1), sleep(300)]},
                  {:default, [custom(&__MODULE__.pick_choice/2), sleep(300)]}
                ]),
                premove(:event_skip)
              ]},
            {:event_skip_unselectable, [click(:event_skip_unselectable)]},
            {:default, [key(:space), click(:event_skip)]}
          ])
        ],
        every: 250,
        timeout: 35_000
      )
    ]
  end

  def pick_choice(frame, ctx) do
    battle_ys = frame |> Matcher.find_all(:event_text_battle) |> Enum.map(&center/1)

    gift =
      frame
      |> Matcher.find_all(:event_text_ego_gift)
      |> Enum.map(fn rect -> {rect, center(rect)} end)
      |> Enum.sort_by(fn {_rect, {_x, y}} -> y end)
      |> Enum.find(fn {_rect, {_x, y}} -> Enum.all?(battle_ys, fn {_bx, by} -> abs(y - by) >= @gift_battle_min_gap end) end)

    case gift do
      {_rect, {x, y}} ->
        Ctx.log(ctx, :info, "event choice: clicking event_text_ego_gift at y=#{y}")

        with {:ok, {sx, sy}} <- Runner.to_screen_point({x, y}) do
          Mouse.click(sx, sy)
          {:ok, nil}
        end

      nil ->
        battle_choices = MapSet.new(battle_ys, fn {_x, y} -> nearest_choice(y) end)
        choice = Enum.find(0..2, 0, &(&1 not in battle_choices))
        Ctx.log(ctx, :info, "event choice: battle on #{inspect(Enum.sort(battle_choices))}, picking event_choice_#{choice}")
        Runner.run_steps([click(:"event_choice_#{choice}")], ctx)
    end
  end

  defp center({x, y, w, h}), do: {x + div(w, 2), y + div(h, 2)}

  defp nearest_choice(y) do
    Enum.min_by(0..2, fn index ->
      {:ok, %{region: region}} = HookRegistry.find(:"event_choice_#{index}")
      {_cx, cy} = center(region)
      abs(y - cy)
    end)
  end
end
