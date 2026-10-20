defmodule StarlightBot.Navigation.Runner do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.{Ctx, Native, Vision.Capture, Vision.Frame, Vision.HookRegistry, Vision.Matcher}
  alias StarlightBot.{Input.Keyboard, Input.Mouse, Input.Premove, Navigation.Action, Navigation.Catalog, Navigation.Screen}

  @poll_interval_ms 100
  @verify_timeout_ms 1_800
  @refinement_timeout_ms 1_000
  @fallback_settle_ms 2_000
  @target_area_fraction 0.25

  def run_plan([], _ctx), do: {:ok, nil}

  def run_plan(transitions, ctx) do
    upcoming = Enum.map(tl(transitions), & &1.steps) ++ [[]]

    transitions
    |> Enum.zip(upcoming)
    |> Enum.reduce_while({:ok, nil}, fn {t, next_steps}, {:ok, last_frame} ->
      Ctx.log(ctx, :info, "→ #{t.to}")
      RunMemory.put(ctx, :step, "→ #{t.to}")

      case run_steps(t.steps, last_frame, ctx, next_steps) do
        {:ok, frame} ->
          case verify_screen(t.to, ctx, next_steps) do
            :ok -> {:cont, {:ok, frame}}
            {:error, _} = err -> {:halt, err}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> tap(fn _ -> RunMemory.put(ctx, :step, nil) end)
    |> case do
      {:ok, _frame} ->
        arrived = List.last(transitions).to

        candidates =
          case Catalog.find_screen(arrived) do
            %Screen{catch_all: true} ->
              Catalog.all_screens()

            found ->
              [found | Catalog.refinements_of(arrived)] |> Enum.reject(&is_nil/1)
          end

        case resolve_refinement(candidates, mono() + @refinement_timeout_ms) do
          {:ok, screen} -> {:ok, screen}
          :unknown -> {:ok, arrived}
        end

      err ->
        err
    end
  end

  def run_action(screen_name, %Action{} = action, ctx) do
    Ctx.log(ctx, :info, "action #{action.name}")
    RunMemory.put(ctx, :step, "action #{action.name}")

    result =
      with {:ok, _frame} <- run_steps(action.steps, nil, ctx, []),
           :ok <- verify_screen(screen_name, ctx) do
        {:ok, screen_name}
      end

    RunMemory.put(ctx, :step, nil)
    result
  end

  def check_screens(screens) do
    case grab_frame() do
      {:error, _} ->
        :unknown

      {:ok, frame} ->
        {roots, children} = partition_roots(screens)

        case localize_level(frame, roots, children) do
          nil -> :unknown
          screen -> {:ok, screen.name}
        end
    end
  end

  def hook_matches?(frame, {:not, hook_spec}), do: not hook_matches?(frame, hook_spec)

  def hook_matches?(frame, {:all, hook_specs}) do
    Enum.all?(hook_specs, &hook_matches?(frame, &1))
  end

  def hook_matches?(frame, {:any, hook_specs}) do
    Enum.any?(hook_specs, &hook_matches?(frame, &1))
  end

  def hook_matches?(frame, hook), do: Matcher.check(frame, hook)

  defp partition_roots(screens) do
    names = MapSet.new(screens, & &1.name)
    Enum.split_with(screens, fn %Screen{refines: parent} -> is_nil(parent) or not MapSet.member?(names, parent) end)
  end

  defp localize_level(frame, candidates, children) do
    candidates
    |> Enum.find(fn %Screen{identity_hook: hook} -> hook != nil and hook_matches?(frame, hook) end)
    |> case do
      nil ->
        nil

      match ->
        kids = Enum.filter(children, &(&1.refines == match.name))

        case localize_level(frame, kids, children) do
          nil -> resolve_unknown_fallback(match, children)
          deeper -> deeper
        end
    end
  end

  defp resolve_unknown_fallback(match, screens) do
    Enum.find(screens, match, &(&1.refines == match.name and is_nil(&1.identity_hook)))
  end

  def fallback_screen?(name) do
    case Catalog.find_screen(name) do
      %Screen{identity_hook: nil, refines: parent} when not is_nil(parent) -> true
      _ -> false
    end
  end

  def settle_fallback({:ok, name} = ok, recheck, deadline \\ mono() + @fallback_settle_ms) do
    cond do
      not fallback_screen?(name) ->
        ok

      not settles?(name) ->
        ok

      mono() >= deadline ->
        ok

      true ->
        Process.sleep(@poll_interval_ms)

        case recheck.() do
          {:ok, _} = next -> settle_fallback(next, recheck, deadline)
          :unknown -> settle_fallback(ok, recheck, deadline)
        end
    end
  end

  defp settles?(name) do
    case Catalog.find_screen(name) do
      %Screen{settle: settle} -> settle
      nil -> true
    end
  end

  defp resolve_refinement(screens, deadline) do
    case check_screens(screens) do
      {:ok, _} = ok ->
        ok

      :unknown ->
        if mono() >= deadline do
          :unknown
        else
          Process.sleep(@poll_interval_ms)
          resolve_refinement(screens, deadline)
        end
    end
  end

  def run_steps(steps, ctx), do: run_steps(steps, nil, ctx, [])

  defp run_steps([], last_frame, _ctx, _upcoming), do: {:ok, last_frame}

  defp run_steps([step | rest], last_frame, ctx, upcoming) do
    cond do
      Ctx.pause_requested?(ctx) ->
        Ctx.log(ctx, :info, "pause requested, stopping before #{inspect(step)}")
        {:error, :window_not_focused}

      Capture.focused?() ->
        ahead = rest ++ upcoming
        maybe_premove(step, ahead, ctx)

        case execute_step(step, last_frame, ctx, ahead) do
          {:ok, new_frame} -> run_steps(rest, new_frame, ctx, upcoming)
          {:error, _} = err -> err
        end

      true ->
        Ctx.log(ctx, :error, "game window lost focus (alt-tabbed?) — aborting before #{inspect(step)}")
        {:error, :window_not_focused}
    end
  end

  defp execute_step({:branch, _clauses, _default_steps} = step, last_frame, ctx, ahead),
    do: run_branch(step, last_frame, ctx, ahead)

  defp execute_step({:branch, _clauses, _default_steps, _wait_ms} = step, last_frame, ctx, ahead),
    do: run_branch(step, last_frame, ctx, ahead)

  defp execute_step({:retry_until, hook, steps, timeout_ms, every_ms, tries}, last_frame, ctx, ahead),
    do: run_retry({:retry_until, hook, steps, timeout_ms, every_ms, tries, nil}, last_frame, ctx, ahead)

  defp execute_step({:retry_until, _, _, _, _, _, _} = step, last_frame, ctx, ahead),
    do: run_retry(step, last_frame, ctx, ahead)

  defp execute_step(step, last_frame, ctx, _ahead), do: execute_step(step, last_frame, ctx)

  defp execute_step({:click, hook_atom}, last_frame, ctx), do: execute_step({:click, hook_atom, []}, last_frame, ctx)

  defp execute_step({:click, hook_atom, opts}, last_frame, ctx) do
    Ctx.log(ctx, :info, "click #{hook_atom}")

    case do_click(hook_atom, opts, last_frame, ctx) do
      :ok ->
        Ctx.log(ctx, :ok, "clicked #{hook_atom}")
        {:ok, nil}

      {:error, reason} ->
        Ctx.log(ctx, :error, "click #{hook_atom} failed: #{inspect(reason)}")
        {:error, {:click_failed, hook_atom, reason}}
    end
  end

  defp execute_step({:move_to, hook_atom}, last_frame, ctx) do
    Ctx.log(ctx, :info, "move_to #{hook_atom}")

    case do_move_to(hook_atom, last_frame, ctx) do
      :ok ->
        Ctx.log(ctx, :ok, "moved to #{hook_atom}")
        {:ok, nil}

      {:error, reason} ->
        Ctx.log(ctx, :error, "move_to #{hook_atom} failed: #{inspect(reason)}")
        {:error, {:move_to_failed, hook_atom, reason}}
    end
  end

  defp execute_step({:premove, hook_atom}, last_frame, ctx) do
    with true <- Premove.enabled?(),
         {:ok, region} <- resolve_target_region(hook_atom, last_frame),
         {:ok, {sx, sy}} <- to_screen_point(sample_target_point(region)),
         {:ok, box} <- to_screen_box(target_box(region)) do
      Ctx.log(ctx, :info, "premove → #{hook_atom}")
      Mouse.premove(sx, sy, box)
    else
      false -> :ok
      {:error, reason} -> Ctx.log(ctx, :info, "premove #{hook_atom} skipped: #{inspect(reason)}")
    end

    {:ok, last_frame}
  end

  defp execute_step({:drag, hook_atom, dx, dy, duration_ms}, last_frame, ctx) do
    Ctx.log(ctx, :info, "drag #{hook_atom} by (#{dx}, #{dy})")

    case do_drag(hook_atom, dx, dy, duration_ms, last_frame, ctx) do
      :ok ->
        Ctx.log(ctx, :ok, "dragged #{hook_atom} by (#{dx}, #{dy})")
        {:ok, nil}

      {:error, reason} ->
        Ctx.log(ctx, :error, "drag #{hook_atom} failed: #{inspect(reason)}")
        {:error, {:drag_failed, hook_atom, reason}}
    end
  end

  defp execute_step({:scroll, dx, dy}, _last_frame, ctx) do
    Ctx.log(ctx, :info, "scroll dx=#{dx} dy=#{dy}")
    Mouse.scroll(dx, dy)
    Ctx.log(ctx, :ok, "scrolled")
    {:ok, nil}
  end

  defp execute_step({:key, key_atom}, _last_frame, ctx) do
    Ctx.log(ctx, :info, "key #{key_atom}")
    Keyboard.press(key_atom)
    Ctx.log(ctx, :ok, "pressed #{key_atom}")
    {:ok, nil}
  end

  defp execute_step({:type, text}, _last_frame, ctx) do
    Ctx.log(ctx, :info, "type #{inspect(text)}")
    Keyboard.type(text)
    Ctx.log(ctx, :ok, "typed #{inspect(text)}")
    {:ok, nil}
  end

  defp execute_step({:custom, fun}, last_frame, ctx) do
    fun.(last_frame, ctx)
  end

  defp execute_step({:await, hook_atom, timeout_ms, _opts}, last_frame, ctx) do
    execute_step({:await, hook_atom, timeout_ms}, last_frame, ctx)
  end

  defp execute_step({:await, hook_atom, timeout_ms}, _last_frame, ctx) do
    Ctx.log(ctx, :info, "await #{inspect(hook_atom)} (#{timeout_ms}ms)")
    deadline = mono() + timeout_ms
    poll_hook(hook_atom, deadline, ctx)
  end

  defp execute_step({:await_any, hooks, timeout_ms}, _last_frame, ctx) do
    Ctx.log(ctx, :info, "await_any #{inspect(hooks)} (#{timeout_ms}ms)")
    deadline = mono() + timeout_ms
    poll_any(hooks, deadline, ctx)
  end

  defp execute_step({:sleep, ms}, _last_frame, ctx) do
    Ctx.log(ctx, :info, "sleep #{ms}ms")
    Process.sleep(ms)
    {:ok, nil}
  end

  defp run_retry({:retry_until, hook, steps, timeout_ms, every_ms, tries, retry_if}, last_frame, ctx, ahead) do
    verb = retry_verb(steps)
    bound_desc = if tries, do: "tries #{tries}", else: "timeout #{timeout_ms}ms"
    Ctx.log(ctx, :info, "#{verb} #{inspect(hook)} (#{bound_desc}, every #{every_ms}ms)")

    case hook_visible?(hook, last_frame) do
      {true, frame} ->
        Ctx.log(ctx, :ok, "#{verb} #{inspect(hook)}: already visible")
        {:ok, frame}

      {false, _} ->
        bound = if tries, do: {:tries, tries}, else: {:deadline, mono() + timeout_ms}

        loop = %{
          hook: hook,
          steps: steps,
          every_ms: every_ms,
          bound: bound,
          retry_if: retry_if,
          ahead: ahead,
          started_at: mono()
        }

        retry_loop(loop, 0, ctx)
    end
  end

  defp run_branch({:branch, clauses, default_steps, wait_ms}, _last_frame, ctx, ahead) do
    Ctx.log(ctx, :info, "branch (waiting up to #{wait_ms}ms)")
    {frame, matched} = poll_branch(clauses, mono() + wait_ms)

    branch_steps =
      case matched do
        {matched_hook, steps} ->
          Ctx.log(ctx, :ok, "branch matched #{inspect(matched_hook)}")
          steps

        nil ->
          Ctx.log(ctx, :info, "branch default after #{wait_ms}ms")
          default_steps
      end

    run_steps(branch_steps, frame, ctx, ahead)
  end

  defp run_branch({:branch, clauses, default_steps}, last_frame, ctx, ahead) do
    Ctx.log(ctx, :info, "branch")

    frame = last_frame || elem(grab_frame(), 1)

    branch_steps =
      if frame do
        case Enum.find(clauses, fn {hook, _} -> hook_matches?(frame, hook) end) do
          {matched_hook, steps} ->
            Ctx.log(ctx, :ok, "branch matched #{inspect(matched_hook)}")
            steps

          nil ->
            Ctx.log(ctx, :info, "branch default")
            default_steps
        end
      else
        Ctx.log(ctx, :info, "branch default (no frame)")
        default_steps
      end

    run_steps(branch_steps, frame, ctx, ahead)
  end

  defp poll_branch(clauses, deadline) do
    frame =
      case grab_frame() do
        {:ok, frame} -> frame
        {:error, _} -> nil
      end

    matched = frame && Enum.find(clauses, fn {hook, _} -> hook_matches?(frame, hook) end)

    cond do
      matched -> {frame, matched}
      mono() >= deadline -> {frame, nil}
      true ->
        Process.sleep(@poll_interval_ms)
        poll_branch(clauses, deadline)
    end
  end

  defp retry_verb([]), do: "wait_until"
  defp retry_verb(_steps), do: "retry_until"

  defp poll_until_match(hook, deadline) do
    if mono() >= deadline do
      :timeout
    else
      case grab_frame() do
        {:ok, frame} ->
          if hook_matches?(frame, hook) do
            {:matched, frame}
          else
            Process.sleep(@poll_interval_ms)
            poll_until_match(hook, deadline)
          end

        {:error, _} ->
          Process.sleep(@poll_interval_ms)
          poll_until_match(hook, deadline)
      end
    end
  end

  defp poll_hook(hook, deadline, ctx) do
    case poll_until_match(hook, deadline) do
      {:matched, frame} ->
        Ctx.log(ctx, :ok, "await #{inspect(hook)}: matched")
        {:ok, frame}

      :timeout ->
        Ctx.log(ctx, :error, "await #{inspect(hook)}: timeout")
        save_timeout_frame(hook, ctx)
        {:error, {:timeout, hook}}
    end
  end

  defp poll_any(hooks, deadline, ctx) do
    if mono() >= deadline do
      Ctx.log(ctx, :error, "await_any #{inspect(hooks)}: timeout")
      save_timeout_frame(hooks, ctx)
      {:error, {:timeout, hooks}}
    else
      case grab_frame() do
        {:ok, frame} ->
          case Enum.find(hooks, &hook_matches?(frame, &1)) do
            nil ->
              Process.sleep(@poll_interval_ms)
              poll_any(hooks, deadline, ctx)

            matched ->
              Ctx.log(ctx, :ok, "await_any: matched #{inspect(matched)}")
              {:ok, frame}
          end

        {:error, _} ->
          Process.sleep(@poll_interval_ms)
          poll_any(hooks, deadline, ctx)
      end
    end
  end

  defp retry_loop(loop, attempt, ctx) do
    if retry_exhausted?(loop.bound, attempt) do
      retry_gave_up(loop, attempt, ctx)
    else
      case run_steps(loop.steps, nil, ctx, []) do
        {:ok, _frame} ->
          if loop.steps != [] and Enum.all?(loop.steps, &self_positioning_step?/1) do
            premove_toward(loop.hook, loop.ahead, ctx)
          end

          await_retry_window(loop, attempt + 1, ctx)

        {:error, _} = err ->
          err
      end
    end
  end

  defp await_retry_window(loop, attempt, ctx) do
    case poll_until_match(loop.hook, mono() + loop.every_ms) do
      {:matched, frame} ->
        Ctx.log(ctx, :ok, "#{retry_verb(loop.steps)} #{inspect(loop.hook)}: matched after #{attempt} attempt(s), #{mono() - loop.started_at}ms")
        {:ok, frame}

      :timeout ->
        cond do
          retry_allowed?(loop.retry_if) ->
            retry_loop(loop, attempt, ctx)

          retry_exhausted?(loop.bound, attempt) ->
            retry_gave_up(loop, attempt, ctx)

          true ->
            Ctx.log(ctx, :info, "#{retry_verb(loop.steps)} #{inspect(loop.hook)}: #{inspect(loop.retry_if)} gone, waiting instead of retrying")
            await_retry_window(loop, attempt + 1, ctx)
        end
    end
  end

  defp retry_gave_up(loop, attempt, ctx) do
    Ctx.log(ctx, :error, "#{retry_verb(loop.steps)} #{inspect(loop.hook)}: gave up after #{attempt} attempt(s), #{mono() - loop.started_at}ms")
    save_timeout_frame(loop.hook, ctx)
    {:error, {:retry_exhausted, loop.hook}}
  end

  defp save_timeout_frame(hook, ctx) do
    with true <- Application.get_env(:starlight_bot, :save_timeout_frames, false),
         {:ok, frame} <- grab_frame() do
      stamp = NaiveDateTime.local_now() |> NaiveDateTime.to_string() |> String.replace([" ", ":", "."], "_")
      name = hook |> inspect() |> String.replace(~r/[^A-Za-z0-9_]+/, "_") |> String.trim("_") |> String.slice(0, 80)
      dir = Path.join(Application.get_env(:starlight_bot, :bot_log_dir, "log"), "timeouts")
      File.mkdir_p!(dir)
      path = Path.expand(Path.join(dir, "#{stamp}_#{name}.png"))
      Evision.imwrite(path, frame.mat)
      Ctx.log(ctx, :info, "saved the screen at the timeout to #{path}")
    end
  end

  defp retry_allowed?(nil), do: true
  defp retry_allowed?(retry_if), do: elem(hook_visible?(retry_if, nil), 0)

  defp self_positioning_step?(step), do: elem(step, 0) in [:click, :move_to, :drag, :key, :type, :sleep]

  defp retry_exhausted?({:tries, max_tries}, attempt), do: attempt >= max_tries
  defp retry_exhausted?({:deadline, deadline}, _attempt), do: mono() >= deadline

  defp hook_visible?(hook, last_frame) do
    case last_frame || grab_frame_or_nil() do
      nil -> {false, nil}
      frame -> {hook_matches?(frame, hook), frame}
    end
  end

  defp grab_frame_or_nil do
    case grab_frame() do
      {:ok, frame} -> frame
      {:error, _} -> nil
    end
  end

  defp verify_screen(screen_name, ctx, upcoming \\ []) do
    case Catalog.find_screen(screen_name) do
      nil ->
        Ctx.log(ctx, :ok, "no identity hook for #{screen_name}, skipping verify")
        :ok

      %Screen{identity_hook: nil} ->
        Ctx.log(ctx, :ok, "#{screen_name} has no identity hook, skipping verify")
        :ok

      screen ->
        premove_toward(screen.identity_hook, upcoming, ctx)
        deadline = mono() + @verify_timeout_ms

        case poll_until_match(screen.identity_hook, deadline) do
          {:matched, _frame} ->
            Ctx.log(ctx, :ok, "verified #{screen_name}")
            :ok

          :timeout ->
            Ctx.log(ctx, :error, "verification failed: #{screen_name} identity hook not found")
            save_timeout_frame(screen.identity_hook, ctx)
            {:error, {:verification_failed, screen_name}}
        end
    end
  end

  defp do_click(hook_atom, opts, last_frame, _ctx) do
    with {:ok, region} <- resolve_target_region(hook_atom, last_frame),
         {:ok, {sx, sy}} <- to_screen_point(sample_target_point(region)),
         {:ok, box} <- to_screen_box(target_box(region)) do
      if Premove.enabled?(), do: Mouse.click(sx, sy, Keyword.put(opts, :within, box)), else: Mouse.click(sx, sy, opts)
      :ok
    end
  end

  defp do_move_to(hook_atom, last_frame, ctx) do
    with {:ok, {sx, sy}} <- resolve_screen_point(hook_atom, last_frame, ctx) do
      Mouse.move_to(sx, sy)
      :ok
    end
  end

  defp do_drag(hook_atom, dx, dy, duration_ms, last_frame, ctx) do
    with {:ok, {sx, sy}} <- resolve_screen_point(hook_atom, last_frame, ctx),
         {:ok, scale} <- window_scale() do
      Mouse.drag({sx, sy}, {sx + round(dx * scale), sy + round(dy * scale)}, duration_ms: duration_ms)
      :ok
    end
  end

  defp target_box({x, y, w, h}) do
    scale = :math.sqrt(@target_area_fraction)
    tw = w * scale
    th = h * scale
    {x + (w - tw) / 2, y + (h - th) / 2, tw, th}
  end

  defp sample_target_point(region) do
    {left, top, tw, th} = target_box(region)
    {left + :rand.uniform() * tw, top + :rand.uniform() * th}
  end

  defp to_screen_box({nx, ny, nw, nh}) do
    case Capture.window_rect() do
      nil -> {:error, :no_window}
      {wx, wy, ww, _wh} ->
        scale = ww / 1920.0
        {:ok, {wx + nx * scale, wy + ny * scale, nw * scale, nh * scale}}
    end
  end

  defp maybe_premove(step, ahead, ctx) do
    case premove_window(step) do
      {:ok, watched} -> premove_toward(watched, ahead, ctx)
      :none -> :ok
    end
  end

  defp premove_window({:await, spec, _timeout}), do: {:ok, spec}
  defp premove_window({:await_any, specs, _timeout}), do: {:ok, {:any, specs}}
  defp premove_window({:retry_until, spec, [], _timeout, _every, _tries}), do: {:ok, spec}
  defp premove_window({:retry_until, spec, [], _timeout, _every, _tries, _retry_if}), do: {:ok, spec}
  defp premove_window({:sleep, _ms}), do: {:ok, nil}
  defp premove_window(_step), do: :none

  defp premove_toward(watched, ahead, ctx) do
    with true <- Premove.enabled?(),
         {:ok, hook_atom} <- next_target(ahead),
         {:ok, hook} <- HookRegistry.find(hook_atom),
         {_, _, _, _} = region <- fixed_region(hook),
         {:ok, {sx, sy}} <- to_screen_point(sample_target_point(region)),
         {:ok, box} <- to_screen_box(target_box(region)) do
      Ctx.log(ctx, :info, "premove → #{hook_atom} (while waiting on #{inspect(watched)})")
      Mouse.premove(sx, sy, box)
    end

    :ok
  end

  defp next_target([{:click, hook} | _]), do: {:ok, hook}
  defp next_target([{:click, hook, _opts} | _]), do: {:ok, hook}
  defp next_target([{:move_to, hook} | _]), do: {:ok, hook}
  defp next_target([{:premove, hook} | _]), do: {:ok, hook}
  defp next_target([{:drag, hook, _dx, _dy, _ms} | _]), do: {:ok, hook}
  defp next_target([{:retry_until, _spec, [_ | _] = steps, _, _, _} | rest]), do: next_target(steps ++ rest)
  defp next_target([{:retry_until, _spec, [_ | _] = steps, _, _, _, _} | rest]), do: next_target(steps ++ rest)
  defp next_target([{:branch, [{_spec, steps} | _], _default} | _]), do: next_target(steps)
  defp next_target([{:branch, [{_spec, steps} | _], _default, _wait_ms} | _]), do: next_target(steps)
  defp next_target([{kind, _} | rest]) when kind in [:key, :type, :sleep], do: next_target(rest)
  defp next_target(_steps), do: :none

  defp fixed_region(hook) do
    cond do
      hook.click_region -> hook.click_region
      hook.scan_region -> nil
      hook.region -> hook.region
      true -> nil
    end
  end

  defp window_scale do
    case Capture.window_rect() do
      nil -> {:error, :no_window}
      {_wx, _wy, ww, _wh} -> {:ok, ww / 1920.0}
    end
  end

  def to_screen_point({nx, ny}) do
    case Capture.window_rect() do
      nil -> {:error, :no_window}
      {wx, wy, ww, _wh} -> {:ok, {round(wx + nx * ww / 1920.0), round(wy + ny * ww / 1920.0)}}
    end
  end

  defp resolve_screen_point(hook_atom, last_frame, _ctx) do
    with {:ok, region} <- resolve_target_region(hook_atom, last_frame) do
      to_screen_point(sample_target_point(region))
    end
  end

  defp resolve_target_region(hook_atom, last_frame) do
    with {:ok, hook} <- HookRegistry.find(hook_atom) do
      case fixed_region(hook) do
        {_, _, _, _} = region ->
          {:ok, region}

        nil ->
          frame_for_find = last_frame || elem(grab_frame(), 1)

          with %Frame{} <- frame_for_find,
               {:ok, region} <- Matcher.find(frame_for_find, hook_atom) do
            {:ok, region}
          else
            _ -> {:error, :no_target}
          end
      end
    end
  end

  defp grab_frame do
    case Native.cache_grab_frame() do
      {:ok, binary, _w, _h} ->
        case Capture.window_rect() do
          nil ->
            Capture.grab_frame()

          window_rect ->
            {:ok, Frame.from_capture(binary, window_rect)}
        end

      {:error, _} ->
        Capture.grab_frame()
    end
  end

  defp mono, do: System.monotonic_time(:millisecond)
end
