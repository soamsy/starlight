defmodule StarlightBot.Navigation.Runner do
  alias StarlightBot.{Ctx, Native, Vision.Capture, Vision.Frame, Vision.HookRegistry, Vision.Matcher}
  alias StarlightBot.{Input.Keyboard, Input.Mouse, Navigation.Action, Navigation.Catalog, Navigation.Screen}

  @poll_interval_ms 100
  @verify_timeout_ms 1_800
  @refinement_timeout_ms 1_000

  def run_plan([], _ctx), do: {:ok, nil}

  def run_plan(transitions, ctx) do
    Enum.reduce_while(transitions, {:ok, nil}, fn t, {:ok, last_frame} ->
      Ctx.log(ctx, :info, "→ #{t.to}")

      case run_steps(t.steps, last_frame, ctx) do
        {:ok, frame} ->
          case verify_screen(t.to, ctx) do
            :ok -> {:cont, {:ok, frame}}
            {:error, _} = err -> {:halt, err}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
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

    with {:ok, _frame} <- run_steps(action.steps, nil, ctx),
         :ok <- verify_screen(screen_name, ctx) do
      {:ok, screen_name}
    end
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

  def run_steps(steps, ctx), do: run_steps(steps, nil, ctx)

  defp run_steps([], last_frame, _ctx), do: {:ok, last_frame}

  defp run_steps([step | rest], last_frame, ctx) do
    if Capture.focused?() do
      case execute_step(step, last_frame, ctx) do
        {:ok, new_frame} -> run_steps(rest, new_frame, ctx)
        {:error, _} = err -> err
      end
    else
      Ctx.log(ctx, :error, "game window lost focus (alt-tabbed?) — aborting before #{inspect(step)}")
      {:error, :window_not_focused}
    end
  end

  defp execute_step({:click, hook_atom}, last_frame, ctx) do
    Ctx.log(ctx, :info, "click #{hook_atom}")

    case do_click(hook_atom, last_frame, ctx) do
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

  defp execute_step({:branch, clauses, default_steps}, last_frame, ctx) do
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

    run_steps(branch_steps, frame, ctx)
  end

  defp execute_step({:sleep, ms}, last_frame, ctx) do
    Ctx.log(ctx, :info, "sleep #{ms}ms")
    Process.sleep(ms)
    {:ok, last_frame}
  end

  defp execute_step({:retry_until, hook, steps, timeout_ms, every_ms, tries}, last_frame, ctx) do
    verb = retry_verb(steps)
    bound_desc = if tries, do: "tries #{tries}", else: "timeout #{timeout_ms}ms"
    Ctx.log(ctx, :info, "#{verb} #{inspect(hook)} (#{bound_desc}, every #{every_ms}ms)")

    case hook_visible?(hook, last_frame) do
      {true, frame} ->
        Ctx.log(ctx, :ok, "#{verb} #{inspect(hook)}: already visible")
        {:ok, frame}

      {false, _} ->
        bound = if tries, do: {:tries, tries}, else: {:deadline, mono() + timeout_ms}
        retry_loop(hook, steps, every_ms, bound, 0, ctx)
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
        {:error, {:timeout, hook}}
    end
  end

  defp poll_any(hooks, deadline, ctx) do
    if mono() >= deadline do
      Ctx.log(ctx, :error, "await_any #{inspect(hooks)}: timeout")
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

  defp retry_loop(hook, steps, every_ms, bound, attempt, ctx) do
    if retry_exhausted?(bound, attempt) do
      Ctx.log(ctx, :error, "#{retry_verb(steps)} #{inspect(hook)}: gave up after #{attempt} attempt(s)")
      {:error, {:retry_exhausted, hook}}
    else
      case run_steps(steps, nil, ctx) do
        {:ok, _frame} ->
          Process.sleep(every_ms)

          case hook_visible?(hook, nil) do
            {true, frame} ->
              Ctx.log(ctx, :ok, "#{retry_verb(steps)} #{inspect(hook)}: matched after #{attempt + 1} attempt(s)")
              {:ok, frame}

            {false, _} ->
              retry_loop(hook, steps, every_ms, bound, attempt + 1, ctx)
          end

        {:error, _} = err ->
          err
      end
    end
  end

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

  defp verify_screen(screen_name, ctx) do
    case Catalog.find_screen(screen_name) do
      nil ->
        Ctx.log(ctx, :ok, "no identity hook for #{screen_name}, skipping verify")
        :ok

      %Screen{identity_hook: nil} ->
        Ctx.log(ctx, :ok, "#{screen_name} has no identity hook, skipping verify")
        :ok

      screen ->
        deadline = mono() + @verify_timeout_ms

        case poll_until_match(screen.identity_hook, deadline) do
          {:matched, _frame} ->
            Ctx.log(ctx, :ok, "verified #{screen_name}")
            :ok

          :timeout ->
            Ctx.log(ctx, :error, "verification failed: #{screen_name} identity hook not found")
            {:error, {:verification_failed, screen_name}}
        end
    end
  end

  defp do_click(hook_atom, last_frame, ctx) do
    with {:ok, {sx, sy}} <- resolve_screen_point(hook_atom, last_frame, ctx) do
      Mouse.visual_click(sx, sy)
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
      Mouse.drag({sx, sy}, {sx + round(dx * scale), sy + round(dy * scale)}, duration_ms)
      :ok
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
    with {:ok, hook} <- HookRegistry.find(hook_atom) do
      fixed_target =
        cond do
          hook.click_region -> hook.click_region
          hook.scan_region -> nil
          hook.region -> hook.region
          true -> nil
        end

      norm_point =
        case fixed_target do
          {cx, cy, cw, ch} -> {cx + div(cw, 2), cy + div(ch, 2)}

          nil ->
            frame_for_find = last_frame || elem(grab_frame(), 1)

            if frame_for_find do
              case Matcher.find(frame_for_find, hook_atom) do
                {:ok, {mx, my, mw, mh}} -> {mx + div(mw, 2), my + div(mh, 2)}
                _ -> nil
              end
            end
        end

      case norm_point do
        nil ->
          {:error, :no_target}

        {nx, ny} ->
          case Capture.window_rect() do
            nil ->
              {:error, :no_window}

            {wx, wy, ww, _wh} ->
              scale = ww / 1920.0
              sx = round(wx + nx * scale)
              sy = round(wy + ny * scale)
              {:ok, {sx, sy}}
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
