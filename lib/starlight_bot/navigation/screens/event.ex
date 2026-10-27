defmodule StarlightBot.Navigation.Screens.Event do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, EventAdvantage}
  alias StarlightBot.Ctx
  alias StarlightBot.Input.Mouse
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.Vision.{Capture, HookRegistry, Matcher}

  @gift_battle_min_gap 100
  @skips [:event_skip, :event_skip_unselectable]
  @actionable [:event_proceed, :event_continue, :event_commence, :event_advantage_none_selected, :event_choices]
  @choice_gone_wait_ms 1_500
  @advantage_proceed_timeout_ms 8_000
  @skip_timeout_ms 8_000
  @advantage_choice_max_dy 100

  screen :event, identity: :event do
    transition to: :event_over, do: play_out_steps()
  end

  screen :event_over, identity: nil, catch_all: true

  def play_out_steps do
    [
      premove(:event_prechoice_region),
      retry_until(
        not_hook(:event),
        [
          branch([
            {:event_proceed, [reclick_until_gone(:event_proceed, every: 60), premove(:event_prechoice_region)]},
            {:event_continue, [reclick_until_gone(:event_continue, every: 60)]},
            {:event_commence, [reclick_until_gone(:event_commence, every: 60)]},
            {:event_advantage_none_selected,
              [
                retry_until(
                  not_hook(:event_advantage_none_selected),
                  [call(EventAdvantage, :select_best_sinner)],
                  every: 200,
                  tries: 20
                )
              ] ++ [await(:event_commence, timeout: 1000), reclick_until_gone(:event_commence, every: 60, timeout: 3000)]},
            {:event_choices, [call(__MODULE__, :choose)]},
            {any_of(@skips), [retry_until(any_of([not_hook(any_of(@skips)) | @actionable]), [key(:space)], every: 60, timeout: @skip_timeout_ms)]},
            {:default, [key(:space), branch([{any_of(@actionable), []}], wait: 60)]}
          ])
        ],
        every: 50,
        timeout: 35_000
      )
    ]
  end

  def choose(_frame, ctx) do

    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, clicked_y} <- click_choice(frame, ctx),
         {:ok, _} = ok <- Runner.run_steps([premove(:event_proceed), branch([{not_hook(:event_choices), []}], wait: @choice_gone_wait_ms)], ctx) do
      cond do
        Engine.check(:event_choices) ->
          Ctx.log(ctx, :info, "event choice: click didn't register, choices still showing")
          ok

        advantage_choice?(frame, clicked_y) ->
          proceed_to_advantage_check(ctx)

        true ->
          ok
      end
    end
  end

  defp proceed_to_advantage_check(ctx) do
    Ctx.log(ctx, :info, "event choice: advantage check ahead (proceed, skip, sinner, commence)")

    await_proceed = retry_until(:event_proceed, [branch([{any_of(@skips), [key(:space)]}])], every: 150, timeout: @advantage_proceed_timeout_ms)

    case Runner.run_steps([await_proceed, reclick_until_gone(:event_proceed, every: 80)], ctx) do
      {:ok, _} ->
        Runner.run_steps([premove(:event_sinner_preselect)], ctx)

      {:error, _} ->
        Ctx.log(ctx, :info, "event choice: proceed never showed after the advantage choice, leaving it to the event loop")
        {:ok, nil}
    end
  end

  defp click_choice(frame, ctx) do
    cond do
      Matcher.check(frame, :event_chicken_1) -> click_choice_hook(:event_choice_0, ctx)
      Matcher.check(frame, :event_chicken_2) -> click_choice_hook(:event_choice_1, ctx)
      true -> pick_choice(frame, ctx)
    end
  end

  defp click_choice_hook(hook, ctx) do
    {:ok, %{region: region}} = HookRegistry.find(hook)
    {_x, y} = center(region)

    with {:ok, _} <- Runner.run_steps([click(hook), click(hook)], ctx), do: {:ok, y}
  end

  defp advantage_choice?(frame, clicked_y) do
    frame
    |> Matcher.find_all(:event_text_advantage)
    |> Enum.any?(fn rect -> abs(elem(center(rect), 1) - clicked_y) <= @advantage_choice_max_dy end)
  end

  def pick_choice(frame, ctx) do
    first_choice = if Matcher.check(frame, :event_choice_0_disabled), do: 1, else: 0
    battle_ys = frame |> Matcher.find_all(:event_text_battle) |> Enum.map(&center/1)

    gift =
      frame
      |> Matcher.find_all(:event_text_ego_gift)
      |> Enum.map(fn rect -> {rect, center(rect)} end)
      |> Enum.sort_by(fn {_rect, {_x, y}} -> y end)
      |> Enum.reject(fn {_rect, {_x, y}} -> nearest_choice(y) < first_choice end)
      |> Enum.find(fn {_rect, {_x, y}} -> Enum.all?(battle_ys, fn {_bx, by} -> abs(y - by) >= @gift_battle_min_gap end) end)

    case gift do
      {_rect, {x, y}} ->
        Ctx.log(ctx, :info, "event choice: clicking event_text_ego_gift at y=#{y}")

        with {:ok, {sx, sy}} <- Runner.to_screen_point({x, y}) do
          Mouse.click(sx, sy)
          {:ok, y}
        end

      nil ->
        battle_choices = MapSet.new(battle_ys, fn {_x, y} -> nearest_choice(y) end)
        choice = Enum.find(first_choice..2, first_choice, &(&1 not in battle_choices))
        Ctx.log(ctx, :info, "event choice: battle on #{inspect(Enum.sort(battle_choices))}, picking event_choice_#{choice}")
        click_choice_hook(:"event_choice_#{choice}", ctx)
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
