defmodule StarlightBot.Automation.Scripts.SurveyTeamHooks do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.Scripts.PrepareLineups
  alias StarlightBot.{Ctx, Teams}
  alias StarlightBot.Vision.{Capture, HookRegistry, Matcher}

  @scroll_clicks 8
  @max_scrolls 14
  @scroll_down_available :team_selector_scroll_down_available
  @scroll_settle_ms 600
  @click_settle_ms 150
  @selected_timeout_ms 1_000

  def program, do: [log(:info, "Localizing…"), locate_screen(then: {__MODULE__, :located, []})]

  def located({:ok, :team_select} = outcome, frame, ctx), do: at_team_select(outcome, frame, ctx)

  def located({:ok, screen}, _frame, _ctx) do
    steps = [goto(screen, :lux_exp), goto(:lux_exp, :team_select)]
    {:steps, [capture(steps, then: {__MODULE__, :at_team_select, []})]}
  end

  def located(:unknown, _frame, ctx) do
    Ctx.log(ctx, :error, "screen not recognized")
    {:error, :unknown_screen}
  end

  def at_team_select({:ok, _screen}, _frame, _ctx) do
    steps = [invoke(__MODULE__, :sweep), key(:esc)]
    {:steps, [capture(steps, then: {__MODULE__, :swept, []})]}
  end

  def at_team_select(error, _frame, _ctx), do: error

  def swept({:ok, _}, frame, ctx), do: PrepareLineups.swept({:ok, nil}, frame, ctx)
  def swept(error, _frame, _ctx), do: error

  defdelegate home(outcome, frame, ctx), to: PrepareLineups
  defdelegate done(outcome, frame, ctx), to: PrepareLineups

  def sweep(ctx) do
    hooks = known_hooks()
    Ctx.log(ctx, :info, "surveying #{length(hooks)} team hook(s)")
    selector = if Engine.check(:team_selector_tall), do: :team_selector_tall, else: :team_selector
    PrepareLineups.scroll_to_top(selector, 0, ctx)
    stats = scan(hooks, selector, 0, %{}, ctx)
    report(hooks, stats, ctx)
    {:ok, :done}
  end

  defp known_hooks do
    Teams.team_hooks()
    |> Enum.flat_map(fn {_label, hooks} -> hooks end)
    |> Enum.uniq()
    |> Enum.flat_map(fn name ->
      case existing_atom(name) do
        nil -> []
        hook -> [hook]
      end
    end)
  end

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp scan(hooks, selector, scrolls, stats, ctx) do
    pending = Enum.reject(hooks, &match?(%{found: true}, stats[&1]))

    case Capture.grab_frame() do
      {:ok, frame} ->
        more? = Matcher.check(frame, @scroll_down_available)
        stats = frame |> Matcher.find_with_score_batch(pending) |> Enum.reduce(stats, &observe(&1, &2, ctx))
        advance(hooks, selector, scrolls, more?, stats, ctx)

      {:error, reason} ->
        Ctx.log(ctx, :error, "frame grab failed: #{inspect(reason)}")
        stats
    end
  end

  defp advance(hooks, selector, scrolls, more?, stats, ctx) do
    cond do
      scrolls >= @max_scrolls ->
        Ctx.log(ctx, :info, "team selector: #{scrolls} scrolls down without reaching the end")
        stats

      not (more? or recheck_more?(selector, ctx)) ->
        Ctx.log(ctx, :info, "team selector: reached the bottom after #{scrolls} scroll(s)")
        stats

      true ->
        Engine.act([move_to(selector), scroll_down(@scroll_clicks), sleep(@scroll_settle_ms)], ctx)
        scan(hooks, selector, scrolls + 1, stats, ctx)
    end
  end

  defp recheck_more?(selector, ctx) do
    Engine.act([move_to(selector), sleep(@scroll_settle_ms)], ctx)
    Engine.check(@scroll_down_available)
  end

  defp observe({hook, {:ok, score, match}, _us}, stats, ctx) do
    best = max(score, get_in(stats, [hook, :best]) || 0.0)
    entry = Map.get(stats, hook, %{found: false, selected: nil, seen: 0})
    entry = %{entry | seen: entry.seen + 1} |> Map.put(:best, best)

    case match do
      {:ok, _rect} ->
        Engine.act([click(hook, settle_ms: @click_settle_ms)], ctx)
        Map.put(stats, hook, %{entry | found: true, selected: selected_score(hook)})

      :not_found ->
        Map.put(stats, hook, entry)
    end
  end

  defp observe({hook, _error, _us}, stats, _ctx), do: Map.put_new(stats, hook, %{found: false, selected: nil, seen: 0, best: nil})

  defp selected_score(hook) do
    selected = existing_atom("#{hook}_selected")

    with false <- is_nil(selected),
         {:ok, _} <- HookRegistry.find(selected) do
      deadline = System.monotonic_time(:millisecond) + @selected_timeout_ms
      poll_selected(selected, deadline, nil)
    else
      _ -> nil
    end
  end

  defp poll_selected(selected, deadline, best) do
    score =
      case Capture.grab_frame() do
        {:ok, frame} ->
          case Matcher.find_with_score(frame, selected) do
            {:ok, score, match} -> {score, match != :not_found}
            _ -> nil
          end

        _ ->
          nil
      end

    best = pick_best(best, score)

    cond do
      match?({_, true}, score) -> best
      System.monotonic_time(:millisecond) >= deadline -> best
      true ->
        Process.sleep(100)
        poll_selected(selected, deadline, best)
    end
  end

  defp pick_best(nil, score), do: score
  defp pick_best(best, nil), do: best
  defp pick_best({a, _} = best, {b, _} = score), do: if(b > a, do: score, else: best)

  defp report(hooks, stats, ctx) do
    rows = Enum.map(hooks, fn hook -> {hook, Map.get(stats, hook), threshold(hook)} end)
    {found, missing} = Enum.split_with(rows, fn {_h, s, _t} -> match?(%{found: true}, s) end)

    Ctx.log(ctx, :info, "found #{length(found)} of #{length(rows)} team hook(s)")
    Enum.each(found, fn {hook, s, t} -> Ctx.log(ctx, :ok, found_line(hook, s, t)) end)
    Enum.each(missing, fn {hook, s, t} -> Ctx.log(ctx, :error, missing_line(hook, s, t)) end)

    margins = for {_h, %{best: best}, t} <- found, is_number(best), is_number(t), do: best - t
    selected_failed = for {h, %{selected: {_, false}}, _t} <- found, do: h

    if margins != [], do: Ctx.log(ctx, :info, margin_summary(margins))

    if selected_failed != [] do
      Ctx.log(ctx, :error, "clicked but selected state not confirmed: #{Enum.map_join(selected_failed, ", ", &Atom.to_string/1)}")
    end

    if missing == [], do: Ctx.log(ctx, :ok, "every known team hook was found"), else: Ctx.log(ctx, :error, "not found: #{Enum.map_join(missing, ", ", fn {h, _, _} -> Atom.to_string(h) end)}")
  end

  defp threshold(hook) do
    case HookRegistry.find(hook) do
      {:ok, %{confidence: confidence}} -> confidence
      _ -> nil
    end
  end

  defp found_line(hook, s, t) do
    "#{hook}: found, score #{fmt(s.best)} (threshold #{fmt(t)}, margin #{signed(s.best, t)}), #{selected_text(s.selected)}"
  end

  defp missing_line(hook, nil, t), do: "#{hook}: no hook definition or never scanned (threshold #{fmt(t)})"

  defp missing_line(hook, s, t) do
    "#{hook}: not found, best score #{fmt(s.best)} (threshold #{fmt(t)}, margin #{signed(s.best, t)}) over #{s.seen} frame(s)"
  end

  defp selected_text(nil), do: "no selected hook to confirm"
  defp selected_text({score, true}), do: "selected confirmed at #{fmt(score)}"
  defp selected_text({score, false}), do: "selected NOT confirmed, best #{fmt(score)}"

  defp margin_summary(margins) do
    n = length(margins)
    mean = Enum.sum(margins) / n
    sd = if n > 1, do: :math.sqrt(Enum.sum(Enum.map(margins, &((&1 - mean) * (&1 - mean)))) / (n - 1)), else: 0.0
    half = 1.96 * sd / :math.sqrt(n)

    "found-hook margin over threshold: n=#{n}, mean #{fmt(mean)}, 95% CI [#{fmt(mean - half)}, #{fmt(mean + half)}], min #{fmt(Enum.min(margins))}, max #{fmt(Enum.max(margins))}"
  end

  defp fmt(nil), do: "n/a"
  defp fmt(value) when is_number(value), do: :erlang.float_to_binary(value * 1.0, decimals: 3)

  defp signed(score, threshold) when is_number(score) and is_number(threshold), do: sign(score - threshold)
  defp signed(_score, _threshold), do: "n/a"

  defp sign(diff), do: (if diff >= 0, do: "+", else: "") <> fmt(diff)
end
