defmodule StarlightBot.Navigation.Machine do
  @behaviour :gen_statem

  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Ctx
  alias StarlightBot.Input.{Keyboard, Mouse, Premove}
  alias StarlightBot.Navigation.{Catalog, Runner, Screen}
  alias StarlightBot.Vision.{Capture, Frame, HookRegistry, Matcher}

  @poll_interval_ms 100
  @verify_timeout_ms 1_800
  @refinement_timeout_ms 1_000
  @hold_poll_ms 30
  @locate_poll_ms 200
  @fallback_settle_ms 2_000
  @target_area_fraction 0.25
  @unguarded_steps [
    :log,
    :fail,
    :attempt,
    :ensure,
    :goto,
    :locate_screen,
    :capture,
    :__mark__,
    :__verify__,
    :__retry_after__,
    :__refine__,
    :__localize__,
    :__done__,
    :__rescue__,
    :__ensure__,
    :__deliver__,
    :__unguarded__
  ]

  def child_spec({program, ctx, opts}),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [program, ctx, opts]}, restart: :temporary}

  def start_link(program, ctx, opts),
    do: :gen_statem.start_link(__MODULE__, {program, ctx, opts}, [])

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init({program, ctx, opts}) do
    data = %{
      reply_to: Keyword.fetch!(opts, :reply_to),
      ctx: ctx,
      stack: program,
      upcoming: Keyword.get(opts, :upcoming, []),
      frame: Keyword.get(opts, :frame),
      result: nil,
      poll: nil
    }

    {:ok, :running, data, [{:next_event, :internal, :step}]}
  end

  @impl true
  def handle_event(:internal, :step, :running, %{stack: []} = data),
    do: finish(data.result || {:ok, data.frame}, data)

  def handle_event(:internal, :step, :running, %{stack: [step | rest]} = data) do
    data = %{data | stack: rest}

    if elem(step, 0) in @unguarded_steps,
      do: exec_internal(step, data),
      else: guarded(step, data)
  end

  def handle_event(:state_timeout, :tick, :polling, data), do: tick(data)

  def handle_event(:state_timeout, :wake, :sleeping, data), do: continue(data, nil)

  defp guarded(step, data) do
    cond do
      Ctx.pause_requested?(data.ctx) ->
        Ctx.log(data.ctx, :info, "pause requested, stopping before #{describe(step)}")
        fail_with({:error, :window_not_focused}, data)

      Capture.focused?() ->
        maybe_premove(step, ahead(data), data.ctx)
        exec(step, data)

      true ->
        Ctx.log(data.ctx, :error, "game window lost focus (alt-tabbed?) — aborting before #{describe(step)}")
        fail_with({:error, :window_not_focused}, data)
    end
  end

  defp exec({:branch, clauses, default_steps}, data) do
    ctx = data.ctx
    Ctx.log(ctx, :info, "branch")

    frame = data.frame || elem(Runner.grab_frame(), 1)

    branch_steps =
      if frame do
        case Enum.find(clauses, fn {hook, _} -> Runner.hook_matches?(frame, hook) end) do
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

    push(branch_steps, frame, data)
  end

  defp exec({:branch, _clauses, _default_steps, wait_ms} = step, data) do
    Ctx.log(data.ctx, :info, "branch (waiting up to #{wait_ms}ms)")
    start_poll(step, wait_ms, data)
  end

  defp exec({:retry_until, hook, steps, timeout_ms, every_ms, tries}, data),
    do: exec({:retry_until, hook, steps, timeout_ms, every_ms, tries, nil}, data)

  defp exec({:retry_until, hook, steps, timeout_ms, every_ms, tries, retry_if}, data) do
    verb = retry_verb(steps)
    bound_desc = if tries, do: "tries #{tries}", else: "timeout #{timeout_ms}ms"
    Ctx.log(data.ctx, :info, "#{verb} #{inspect(hook)} (#{bound_desc}, every #{every_ms}ms)")

    case hook_visible?(hook, data.frame) do
      {true, frame} ->
        Ctx.log(data.ctx, :ok, "#{verb} #{inspect(hook)}: already visible")
        continue(data, frame)

      {false, _} ->
        bound = if tries, do: {:tries, tries}, else: {:deadline, mono() + timeout_ms}

        loop = %{
          hook: hook,
          steps: steps,
          every_ms: every_ms,
          bound: bound,
          retry_if: retry_if,
          ahead: ahead(data),
          started_at: mono()
        }

        retry_loop(loop, 0, data)
    end
  end

  defp exec({:await, hook, timeout_ms, _opts}, data), do: exec({:await, hook, timeout_ms}, data)

  defp exec({:await, hook, timeout_ms}, data) do
    Ctx.log(data.ctx, :info, "await #{inspect(hook)} (#{timeout_ms}ms)")
    start_poll({:await, hook}, timeout_ms, data)
  end

  defp exec({:await_any, hooks, timeout_ms}, data) do
    Ctx.log(data.ctx, :info, "await_any #{inspect(hooks)} (#{timeout_ms}ms)")
    start_poll({:await_any, hooks}, timeout_ms, data)
  end

  defp exec({:hold, spec, hold_ms, within_ms, else_steps}, data),
    do: start_poll({:hold, spec, hold_ms, else_steps, nil}, within_ms, data)

  defp exec({:leave_screen, screen_name, timeout_ms}, data),
    do: start_poll({:leave, screen_name, mono()}, timeout_ms, data)

  defp exec({:sleep, ms}, data) do
    Ctx.log(data.ctx, :info, "sleep #{ms}ms")
    {:next_state, :sleeping, data, [{:state_timeout, ms, :wake}]}
  end

  defp exec(step, data) do
    case execute_step(step, data.frame, data.ctx) do
      {:ok, frame} -> continue(data, frame)
      {:steps, steps} -> push(steps, data.frame, data)
      {:error, _} = err -> fail_with(err, data)
    end
  end

  defp exec_internal({:log, kind, text}, data) do
    Ctx.log(data.ctx, kind, text)
    continue(data, data.frame)
  end

  defp exec_internal({:fail, reason}, data), do: fail_with({:error, reason}, data)

  defp exec_internal({:attempt, steps, fallback}, data),
    do: push(steps ++ [{:__rescue__, fallback}], data.frame, data)

  defp exec_internal({:ensure, steps, cleanup}, data),
    do: push(steps ++ [{:__ensure__, cleanup}], data.frame, data)

  defp exec_internal({:goto, from, to, then}, data) do
    steps =
      if from == to do
        [{:log, :ok, "already at #{from}"}, {:__done__, {:ok, from}}]
      else
        case Catalog.plan_path(from, to) do
          {:ok, transitions} -> Runner.plan_program(transitions) ++ [{:__mark__, nil}]
          {:error, :no_path} -> [{:fail, {:no_path, from, to}}]
        end
      end

    push(with_delivery(steps, then), data.frame, data)
  end

  defp exec_internal({:capture, steps, then}, data), do: push(with_delivery(steps, then), data.frame, data)

  defp exec_internal({:locate_screen, timeout_ms, then}, data) do
    data = %{data | stack: with_delivery([], then) ++ data.stack}
    start_poll({:locate, mono()}, timeout_ms, data)
  end

  defp exec_internal({:__deliver__, {mod, fun, args}}, data),
    do: push([{:call, {mod, fun, args ++ [data.result]}}], data.frame, %{data | result: nil})

  defp exec_internal({:__rescue__, _fallback}, data), do: continue(data, data.frame)

  defp exec_internal({:__ensure__, cleanup}, data), do: push(unguarded(cleanup), data.frame, data)

  defp exec_internal({:__unguarded__, step}, data) do
    if elem(step, 0) in @unguarded_steps,
      do: exec_internal(step, data),
      else: exec(step, data)
  end

  defp exec_internal({:__mark__, nil}, data) do
    RunMemory.put(data.ctx, :step, nil)
    continue(data, data.frame)
  end

  defp exec_internal({:__mark__, text}, data) do
    Ctx.log(data.ctx, :info, text)
    RunMemory.put(data.ctx, :step, text)
    continue(data, data.frame)
  end

  defp exec_internal({:__verify__, screen_name}, data) do
    case Catalog.find_screen(screen_name) do
      nil ->
        Ctx.log(data.ctx, :ok, "no identity hook for #{screen_name}, skipping verify")
        continue(data, data.frame)

      %Screen{identity_hook: nil} ->
        Ctx.log(data.ctx, :ok, "#{screen_name} has no identity hook, skipping verify")
        continue(data, data.frame)

      screen ->
        premove_toward(screen.identity_hook, ahead(data), data.ctx)
        start_poll({:verify, screen_name, screen.identity_hook}, @verify_timeout_ms, data)
    end
  end

  defp exec_internal({:__retry_after__, loop, attempt}, data) do
    if loop.steps != [] and Enum.all?(loop.steps, &self_positioning_step?/1) do
      premove_toward(loop.hook, loop.ahead, data.ctx)
    end

    start_poll({:retry_window, loop, attempt + 1}, loop.every_ms, data)
  end

  defp exec_internal({:__refine__, arrived}, data) do
    candidates =
      case Catalog.find_screen(arrived) do
        %Screen{catch_all: true} -> Catalog.all_screens()
        found -> [found | Catalog.refinements_of(arrived)] |> Enum.reject(&is_nil/1)
      end

    start_poll({:refine, candidates, arrived}, @refinement_timeout_ms, data)
  end

  defp exec_internal({:__localize__, screens}, data),
    do: continue(%{data | result: Runner.check_screens(screens)}, data.frame)

  defp exec_internal({:__done__, result}, data), do: continue(%{data | result: result}, data.frame)

  defp start_poll(kind, timeout_ms, data), do: tick(%{data | poll: {kind, mono() + timeout_ms}})

  defp tick(%{poll: {{:hold, spec, hold_ms, else_steps, since}, deadline}} = data) do
    now = mono()
    since = if elem(hook_visible?(spec, nil), 0), do: since || now, else: nil

    cond do
      since && now - since >= hold_ms ->
        continue(data, nil)

      now >= deadline ->
        push(else_steps, nil, data)

      true ->
        poll = {{:hold, spec, hold_ms, else_steps, since}, deadline}
        {:next_state, :polling, %{data | poll: poll}, [{:state_timeout, @hold_poll_ms, :tick}]}
    end
  end

  defp tick(%{poll: {{:settle, current}, deadline}} = data) do
    current =
      case Runner.check_screens(Catalog.all_screens()) do
        {:ok, _} = next -> next
        :unknown -> current
      end

    settle(current, deadline, data)
  end

  defp tick(%{poll: {kind, deadline}} = data) do
    if not grab_first?(kind) and mono() >= deadline do
      expire(kind, nil, data)
    else
      case probe(kind) do
        {:matched, frame, match} ->
          matched(kind, frame, match, data)

        {:miss, frame} ->
          if grab_first?(kind) and mono() >= deadline,
            do: expire(kind, frame, data),
            else: {:next_state, :polling, data, [{:state_timeout, poll_interval(kind), :tick}]}
      end
    end
  end

  defp grab_first?(kind), do: elem(kind, 0) in [:branch, :refine, :leave, :locate]

  defp poll_interval({:locate, _started_at}), do: @locate_poll_ms
  defp poll_interval(_kind), do: @poll_interval_ms

  defp settle({:ok, name} = current, deadline, data) do
    if Runner.fallback_screen?(name) and Runner.settles?(name) and mono() < deadline,
      do: {:next_state, :polling, %{data | poll: {{:settle, current}, deadline}}, [{:state_timeout, @poll_interval_ms, :tick}]},
      else: continue(%{data | result: current}, data.frame)
  end

  defp probe({:refine, candidates, _arrived}) do
    case Runner.check_screens(candidates) do
      {:ok, screen} -> {:matched, nil, screen}
      :unknown -> {:miss, nil}
    end
  end

  defp probe({:locate, _started_at}) do
    case Runner.check_screens(Catalog.all_screens()) do
      {:ok, screen} -> {:matched, nil, screen}
      :unknown -> {:miss, nil}
    end
  end

  defp probe({:leave, screen_name, _started_at}) do
    case Runner.check_screens(Catalog.all_screens()) do
      {:ok, next_screen} when next_screen != screen_name -> {:matched, nil, next_screen}
      _ -> {:miss, nil}
    end
  end

  defp probe(kind) do
    case Runner.grab_frame() do
      {:ok, frame} ->
        case find_match(kind, frame) do
          nil -> {:miss, frame}
          match -> {:matched, frame, match}
        end

      {:error, _} ->
        {:miss, nil}
    end
  end

  defp find_match({:await_any, hooks}, frame), do: Enum.find(hooks, &Runner.hook_matches?(frame, &1))

  defp find_match({:branch, clauses, _default_steps, _wait_ms}, frame),
    do: Enum.find(clauses, fn {hook, _} -> Runner.hook_matches?(frame, hook) end)

  defp find_match(kind, frame), do: Runner.hook_matches?(frame, watched_hook(kind)) || nil

  defp watched_hook({:await, hook}), do: hook
  defp watched_hook({:retry_window, loop, _attempt}), do: loop.hook
  defp watched_hook({:verify, _screen_name, hook}), do: hook

  defp matched({:await, hook}, frame, _match, data) do
    Ctx.log(data.ctx, :ok, "await #{inspect(hook)}: matched")
    continue(data, frame)
  end

  defp matched({:await_any, _hooks}, frame, hook, data) do
    Ctx.log(data.ctx, :ok, "await_any: matched #{inspect(hook)}")
    continue(data, frame)
  end

  defp matched({:branch, _clauses, _default_steps, _wait_ms}, frame, {matched_hook, steps}, data) do
    Ctx.log(data.ctx, :ok, "branch matched #{inspect(matched_hook)}")
    push(steps, frame, data)
  end

  defp matched({:retry_window, loop, attempt}, frame, _match, data) do
    Ctx.log(data.ctx, :ok, "#{retry_verb(loop.steps)} #{inspect(loop.hook)}: matched after #{attempt} attempt(s), #{mono() - loop.started_at}ms")
    continue(data, frame)
  end

  defp matched({:verify, screen_name, _hook}, _frame, _match, data) do
    Ctx.log(data.ctx, :ok, "verified #{screen_name}")
    continue(data, data.frame)
  end

  defp matched({:locate, _started_at}, _frame, screen, data),
    do: settle({:ok, screen}, mono() + @fallback_settle_ms, data)

  defp matched({:leave, screen_name, started_at}, _frame, next_screen, data) do
    Ctx.log(data.ctx, :info, "left #{screen_name} for #{next_screen} after #{mono() - started_at}ms")
    continue(data, nil)
  end

  defp matched({:refine, _candidates, _arrived}, _frame, screen, data),
    do: continue(%{data | result: {:ok, screen}}, data.frame)

  defp expire({:await, hook}, _frame, data) do
    Ctx.log(data.ctx, :error, "await #{inspect(hook)}: timeout")
    save_timeout_frame(hook, data.ctx)
    fail_with({:error, {:timeout, hook}}, data)
  end

  defp expire({:await_any, hooks}, _frame, data) do
    Ctx.log(data.ctx, :error, "await_any #{inspect(hooks)}: timeout")
    save_timeout_frame(hooks, data.ctx)
    fail_with({:error, {:timeout, hooks}}, data)
  end

  defp expire({:branch, _clauses, default_steps, wait_ms}, frame, data) do
    Ctx.log(data.ctx, :info, "branch default after #{wait_ms}ms")
    push(default_steps, frame, data)
  end

  defp expire({:retry_window, loop, attempt}, _frame, data) do
    cond do
      retry_allowed?(loop.retry_if) ->
        retry_loop(loop, attempt, data)

      retry_exhausted?(loop.bound, attempt) ->
        retry_gave_up(loop, attempt, data)

      true ->
        Ctx.log(data.ctx, :info, "#{retry_verb(loop.steps)} #{inspect(loop.hook)}: #{inspect(loop.retry_if)} gone, waiting instead of retrying")
        start_poll({:retry_window, loop, attempt + 1}, loop.every_ms, data)
    end
  end

  defp expire({:verify, screen_name, hook}, _frame, data) do
    Ctx.log(data.ctx, :error, "verification failed: #{screen_name} identity hook not found")
    save_timeout_frame(hook, data.ctx)
    fail_with({:error, {:verification_failed, screen_name}}, data)
  end

  defp expire({:locate, _started_at}, _frame, data), do: continue(%{data | result: :unknown}, data.frame)

  defp expire({:leave, screen_name, started_at}, _frame, data) do
    Ctx.log(data.ctx, :info, "still on #{screen_name} after #{mono() - started_at}ms")
    continue(data, nil)
  end

  defp expire({:refine, _candidates, arrived}, _frame, data),
    do: continue(%{data | result: {:ok, arrived}}, data.frame)

  defp retry_loop(loop, attempt, data) do
    if retry_exhausted?(loop.bound, attempt),
      do: retry_gave_up(loop, attempt, data),
      else: push(loop.steps ++ [{:__retry_after__, loop, attempt}], nil, data)
  end

  defp retry_gave_up(loop, attempt, data) do
    Ctx.log(data.ctx, :error, "#{retry_verb(loop.steps)} #{inspect(loop.hook)}: gave up after #{attempt} attempt(s), #{mono() - loop.started_at}ms")
    save_timeout_frame(loop.hook, data.ctx)
    fail_with({:error, {:retry_exhausted, loop.hook}}, data)
  end

  defp push(steps, frame, data), do: continue(%{data | stack: steps ++ data.stack}, frame)

  defp continue(data, frame),
    do: {:next_state, :running, %{data | frame: frame, poll: nil}, [{:next_event, :internal, :step}]}

  defp fail_with({:error, reason} = err, data) do
    case Enum.drop_while(data.stack, &(not handler?(&1))) do
      [] -> finish(err, data)
      [{:__rescue__, {mod, fun, args}} | rest] -> push([{:call, {mod, fun, args ++ [err]}}], nil, %{data | stack: rest})
      [{:__rescue__, fallback} | rest] -> push(fallback, nil, %{data | stack: rest})
      [{:__ensure__, cleanup} | rest] -> push(unguarded(cleanup) ++ [{:fail, reason}], nil, %{data | stack: rest})
      [{:__deliver__, {mod, fun, args}} | rest] -> push([{:call, {mod, fun, args ++ [err]}}], nil, %{data | stack: rest})
    end
  end

  defp handler?(step), do: elem(step, 0) in [:__rescue__, :__ensure__, :__deliver__]

  defp with_delivery(steps, nil), do: steps
  defp with_delivery(steps, then), do: steps ++ [{:__deliver__, then}]

  defp unguarded(steps), do: Enum.map(steps, &{:__unguarded__, &1})

  defp finish(result, %{reply_to: {pid, tag}} = data) do
    send(pid, {tag, result})
    {:stop, :normal, data}
  end

  defp ahead(data), do: data.stack ++ data.upcoming

  defp describe({:call, {mod, fun, _args}}), do: "#{inspect(mod)}.#{fun}"
  defp describe(step) when tuple_size(step) > 2, do: "#{elem(step, 0)} #{inspect(elem(step, 1), limit: 5, printable_limit: 80)}"
  defp describe(step), do: inspect(step, limit: 5, printable_limit: 80)

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
         {:ok, {sx, sy}} <- Runner.to_screen_point(sample_target_point(region)),
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

  defp execute_step({:call, {mod, fun, args}}, last_frame, ctx) do
    apply(mod, fun, args ++ [last_frame, ctx])
  end

  defp execute_step({:mouse_button, button, true}, _last_frame, _ctx) do
    Mouse.mouse_down(button)
    {:ok, nil}
  end

  defp execute_step({:mouse_button, button, false}, _last_frame, _ctx) do
    Mouse.mouse_up(button)
    {:ok, nil}
  end

  defp retry_verb([]), do: "wait_until"
  defp retry_verb(_steps), do: "retry_until"

  defp save_timeout_frame(hook, ctx) do
    with true <- Application.get_env(:starlight_bot, :save_timeout_frames, false),
         {:ok, frame} <- Runner.grab_frame() do
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
      frame -> {Runner.hook_matches?(frame, hook), frame}
    end
  end

  defp grab_frame_or_nil do
    case Runner.grab_frame() do
      {:ok, frame} -> frame
      {:error, _} -> nil
    end
  end

  defp do_click(hook_atom, opts, last_frame, _ctx) do
    with {:ok, region} <- resolve_target_region(hook_atom, last_frame),
         {:ok, {sx, sy}} <- Runner.to_screen_point(sample_target_point(region)),
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
         {:ok, {sx, sy}} <- Runner.to_screen_point(sample_target_point(region)),
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
  defp next_target([{kind, _} | rest]) when kind in [:key, :type, :sleep, :__mark__, :__verify__], do: next_target(rest)
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

  defp resolve_screen_point(hook_atom, last_frame, _ctx) do
    with {:ok, region} <- resolve_target_region(hook_atom, last_frame) do
      Runner.to_screen_point(sample_target_point(region))
    end
  end

  defp resolve_target_region(hook_atom, last_frame) do
    with {:ok, hook} <- HookRegistry.find(hook_atom) do
      case fixed_region(hook) do
        {_, _, _, _} = region ->
          {:ok, region}

        nil ->
          frame_for_find = last_frame || elem(Runner.grab_frame(), 1)

          with %Frame{} <- frame_for_find,
               {:ok, region} <- Matcher.find(frame_for_find, hook_atom) do
            {:ok, region}
          else
            _ -> {:error, :no_target}
          end
      end
    end
  end

  defp mono, do: System.monotonic_time(:millisecond)
end
