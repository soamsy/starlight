defmodule StarlightBot.Navigation.Runner do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.{Vision.Capture, Vision.Frame, Vision.Matcher}
  alias StarlightBot.Navigation.{Action, Catalog, Machine, Screen}
  alias StarlightBot.Input.Mouse

  @poll_interval_ms 100
  @fallback_settle_ms 2_000

  def run_plan([], _ctx), do: {:ok, nil}

  def run_plan(transitions, ctx) do
    result = run_machine(plan_program(transitions), ctx)
    RunMemory.put(ctx, :step, nil)
    result
  end

  def run_action(screen_name, %Action{} = action, ctx) do
    result = run_machine(action_program(screen_name, action), ctx)
    RunMemory.put(ctx, :step, nil)
    result
  end

  def run_steps(steps, ctx), do: run_machine(steps, ctx)

  def plan_program(transitions) do
    Enum.flat_map(transitions, fn t -> [{:__mark__, "→ #{t.to}"} | t.steps] ++ [{:__verify__, t.to}] end) ++
      [{:__refine__, List.last(transitions).to}]
  end

  def action_program(screen_name, %Action{} = action),
    do: [{:__mark__, "action #{action.name}"} | action.steps] ++ [{:__verify__, screen_name}, {:__done__, {:ok, screen_name}}]

  def localize_program(screens), do: [{:__localize__, screens}]

  defp run_machine(program, ctx) do
    tag = make_ref()
    {:ok, pid} = Machine.start_link(program, ctx, reply_to: {self(), tag}, parent: self())
    ref = Process.monitor(pid)

    receive do
      {^tag, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        exit(reason)
    end
  end

  def check_screens(screens) do
    case grab_for(Enum.map(screens, & &1.identity_hook)) do
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
    |> Task.async_stream(
      fn %Screen{identity_hook: hook} = screen -> {screen, hook != nil and hook_matches?(frame, hook)} end,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity
    )
    |> Enum.find_value(fn {:ok, {screen, matched?}} -> if matched?, do: screen end)
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
        Mouse.dwell(@poll_interval_ms)

        case recheck.() do
          {:ok, _} = next -> settle_fallback(next, recheck, deadline)
          :unknown -> settle_fallback(ok, recheck, deadline)
        end
    end
  end

  def settles?(name) do
    case Catalog.find_screen(name) do
      %Screen{settle: settle} -> settle
      nil -> true
    end
  end

  def to_screen_point({nx, ny}) do
    case Capture.window_rect() do
      nil -> {:error, :no_window}
      {wx, wy, ww, _wh} -> {:ok, {round(wx + nx * ww / 1920.0), round(wy + ny * ww / 1920.0)}}
    end
  end

  def grab_frame, do: Capture.grab_frame()

  def grab_for(specs) do
    case spec_rects(specs) do
      [] -> grab_frame()
      rects -> Capture.grab_regions(rects)
    end
  end

  def frame_for(specs, %Frame{} = frame) do
    if Frame.covers?(frame, spec_rects(specs)), do: {:ok, frame}, else: grab_for(specs)
  end

  def frame_for(specs, nil), do: grab_for(specs)

  def spec_rects(specs) do
    rects = specs |> List.wrap() |> Enum.flat_map(&spec_hooks/1) |> Enum.map(&Matcher.search_rect/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    Enum.reject(rects, fn rect -> Enum.any?(rects, &(&1 != rect and contains?(&1, rect))) end)
  end

  defp spec_hooks({:not, spec}), do: spec_hooks(spec)
  defp spec_hooks({combinator, specs}) when combinator in [:any, :all], do: Enum.flat_map(specs, &spec_hooks/1)
  defp spec_hooks(hook) when is_atom(hook) and not is_nil(hook), do: [hook]
  defp spec_hooks(_spec), do: []

  defp contains?({ox, oy, ow, oh}, {x, y, w, h}), do: x >= ox and y >= oy and x + w <= ox + ow and y + h <= oy + oh

  defp mono, do: System.monotonic_time(:millisecond)
end
