defmodule StarlightBot.Input.Mouse do
  use GenServer
  require Logger
  alias StarlightBot.{AppSettings, LogStore, Native, Input.MouseProfile, Input.Trajectory, Input.Wander, Vision.Capture}

  @btn_left 0x110
  @btn_right 0x111
  @scroll_click_delay_ms 60
  @scroll_click_delay_sigma 15
  @drag_settle_ms 100
  @mouse_down_settle_ms 30
  @release_settle_ms 50
  @click_settle_ms 2
  @land_check_delay_ms 5
  @land_tolerance_px 3
  @land_attempts 3
  @wander_max_ms 60_000
  @wander_tick_ms 12
  @wander_focus_check_ms 250
  @resync_idle_ms 60_000
  @resync_every_moves 25

  defstruct current_pos: {960, 540}, last_velocity: {0.0, 0.0}, held: MapSet.new(), premove: nil, last_move_at: nil, moves_since_sync: 0

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def move_to(x, y, opts \\ []) do
    GenServer.call(__MODULE__, {:move_to, x, y, opts}, 10_000)
  end

  def premove(x, y, within) do
    GenServer.cast(__MODULE__, {:premove, x, y, within})
  end

  def idle do
    GenServer.cast(__MODULE__, :idle)
  end

  def click(x, y, opts \\ []) do
    GenServer.call(__MODULE__, {:click, x, y, :left, opts}, 15_000)
  end

  def click_here(button \\ :left) do
    GenServer.call(__MODULE__, {:click_here, button}, 10_000)
  end

  def right_click(x, y, opts \\ []) do
    GenServer.call(__MODULE__, {:click, x, y, :right, opts}, 10_000)
  end

  def double_click(x, y, opts \\ []) do
    GenServer.call(__MODULE__, {:double_click, x, y, opts}, 10_000)
  end

  def drag(from, to, opts \\ []) do
    GenServer.call(__MODULE__, {:drag, from, to, opts}, 15_000)
  end

  def mouse_down(button \\ :left) do
    GenServer.call(__MODULE__, {:button, button, true})
  end

  def mouse_up(button \\ :left) do
    GenServer.call(__MODULE__, {:button, button, false})
  end

  def scroll(dx, dy) do
    GenServer.call(__MODULE__, {:scroll, dx, dy}, 10_000)
  end

  def release_all do
    GenServer.cast(__MODULE__, :release_all)
  end

  @impl true
  def init(_opts) do
    Logger.info("Input.Mouse starting — initializing input", module: __MODULE__)

    case Native.init_input(Application.get_env(:starlight_bot, :game_window_title, "LimbusCompany"), StarlightBot.Data.portal_token_path()) do
      :ok ->
        Logger.info("Input device ready (#{Native.input_backend()})", module: __MODULE__)
      {:error, reason} ->
        Logger.error(
          "Input initialization failed: #{inspect(reason)}. " <>
          "Neither libei (KWin EIS, RemoteDesktop portal) nor the Wayland virtual pointer and keyboard is available; run the Linux Checks page. " <>
          "Input injection will not work.",
          module: __MODULE__
        )
    end

    :persistent_term.put({__MODULE__, :absolute}, match?({:error, _}, Native.get_cursor_pos()))
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:click, _x, _y, _button, opts} = msg, from, %{premove: %{} = pm} = state) do
    state =
      case Keyword.get(opts, :within) do
        nil -> halt_premove(state)
        within -> if targets?(pm, within), do: finish_premove(state), else: halt_premove(state)
      end

    handle_call(msg, from, state)
  end

  def handle_call(msg, from, %{premove: %{}} = state) do
    handle_call(msg, from, halt_premove(state))
  end

  def handle_call({:move_to, x, y, opts}, _from, state) do
    {new_state, _waypoints} = execute_move(state, x, y, opts)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:click, x, y, button, opts}, _from, state) do
    within = Keyword.get(opts, :within)

    new_state =
      if within != nil and inside?(start_pos(state), within) do
        LogStore.append(:step, "premove: cursor already on target, clicking in place")
        state
      else
        elem(execute_move(state, x, y, opts), 0)
      end

    new_state = land(new_state, x, y, within, opts, @land_attempts)

    do_click(button)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:click_here, button}, _from, state) do
    do_click(button)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:double_click, x, y, opts}, _from, state) do
    {new_state, _waypoints} = execute_move(state, x, y, opts)
    do_click(:left)
    :timer.sleep(80)
    do_click(:left)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:drag, {fx, fy}, {tx, ty}, opts}, _from, state) do
    {new_state, _} = execute_move(state, fx, fy, [])
    :timer.sleep(Keyword.get(opts, :settle_ms, @drag_settle_ms))
    Native.button_event(@btn_left, true)
    :timer.sleep(Keyword.get(opts, :mouse_down_settle_ms, @mouse_down_settle_ms))
    {final_state, _} = execute_move(new_state, tx, ty, [duration_override: Keyword.get(opts, :duration_ms)])
    :timer.sleep(Keyword.get(opts, :release_settle_ms, @release_settle_ms))
    Native.button_event(@btn_left, false)
    {:reply, :ok, final_state}
  end

  @impl true
  def handle_call({:button, button, pressed}, _from, state) do
    btn_code = if button == :left, do: @btn_left, else: @btn_right
    Native.button_event(btn_code, pressed)
    held = if pressed, do: MapSet.put(state.held, button), else: MapSet.delete(state.held, button)
    {:reply, :ok, %{state | held: held}}
  end

  @impl true
  def handle_call({:scroll, dx, dy}, _from, state) do
    scroll_human(dx, dy, MouseProfile.scroll_delay_mult())
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:premove, x, y, within}, state) do
    cond do
      MapSet.size(state.held) > 0 ->
        LogStore.append(:step, "premove skipped: mouse button held")
        {:noreply, state}

      state.premove != nil and targets?(state.premove, within) ->
        {:noreply, state}

      true ->
        {:noreply, state |> halt_premove() |> start_premove(x, y, within)}
    end
  end

  def handle_cast(:idle, state) do
    if MapSet.size(state.held) > 0 or state.premove != nil do
      {:noreply, state}
    else
      {:noreply, start_idle(state)}
    end
  end

  def handle_cast(:release_all, state) do
    Native.button_event(@btn_left, false)
    Native.button_event(@btn_right, false)
    Native.release_all_inputs([])
    {:noreply, %{halt_premove(state) | last_velocity: {0.0, 0.0}, held: MapSet.new()}}
  end

  @impl true
  def handle_info({:premove_tick, ref}, %{premove: %{ref: ref} = pm} = state) do
    case pm.remaining do
      [] ->
        {:noreply, %{state | premove: begin_wander(pm)}}

      [{wx, wy, t} = waypoint | rest] ->
        {px, py, prev_t} = pm.last
        step({px, py}, {wx, wy})
        Process.send_after(self(), {:premove_tick, ref}, max(round(t - prev_t), 0))
        {:noreply, %{state | premove: %{pm | remaining: rest, prev: pm.last, last: waypoint}}}
    end
  end

  def handle_info({:premove_tick, _stale_ref}, state), do: {:noreply, state}

  def handle_info({:wander_tick, ref}, %{premove: %{ref: ref, wander: %Wander{}} = pm} = state) do
    now = System.monotonic_time(:millisecond)

    if now < pm.wander_until and still_focused(pm, now) do
      {lx, ly, lt} = pm.last
      wander = Wander.step(pm.wander, (now - lt) / 1000)
      {wx, wy} = wander.pos
      step({lx, ly}, {wx, wy})
      Process.send_after(self(), {:wander_tick, ref}, @wander_tick_ms)
      focus_at = if now - pm.focus_at >= @wander_focus_check_ms, do: now, else: pm.focus_at
      {:noreply, %{state | premove: %{pm | wander: wander, prev: pm.last, last: {wx, wy, now}, focus_at: focus_at}}}
    else
      {:noreply, halt_premove(state)}
    end
  end

  def handle_info({:wander_tick, _stale_ref}, state), do: {:noreply, state}

  defp still_focused(pm, now), do: now - pm.focus_at < @wander_focus_check_ms or game_focused?()

  defp game_focused? do
    match?({:ok, true}, Native.is_window_focused(Application.get_env(:starlight_bot, :game_window_class, "LimbusCompany")))
  end

  defp targets?(%{target: nil}, _within), do: false
  defp targets?(%{target: target}, within), do: inside?(target, within)

  defp begin_wander(pm) do
    {lx, ly, _} = pm.last
    now = System.monotonic_time(:millisecond)

    case Wander.area(pm.within, Capture.window_rect()) do
      nil ->
        pm

      area ->
        send(self(), {:wander_tick, pm.ref})
        %{pm | wander: Wander.new(area, {lx, ly}), wander_until: now + @wander_max_ms, focus_at: now, prev: nil, last: {lx, ly, now}}
    end
  end

  defp start_premove(state, tx, ty, within) do
    state = sync(state)
    {fx, fy} = start_pos(state)

    waypoints =
      if inside?({fx, fy}, within),
        do: [],
        else: Trajectory.build({fx * 1.0, fy * 1.0}, {tx * 1.0, ty * 1.0}, state.last_velocity, MouseProfile.move_duration_mult())

    begin_premove(state, {tx, ty}, within, waypoints, {fx * 1.0, fy * 1.0})
  end

  defp start_idle(state) do
    state = sync(state)
    {fx, fy} = start_pos(state)
    begin_premove(state, nil, nil, [], {fx * 1.0, fy * 1.0})
  end

  defp begin_premove(state, target, within, waypoints, {fx, fy}) do
    ref = make_ref()
    send(self(), {:premove_tick, ref})

    premove = %{
      ref: ref,
      target: target,
      within: within,
      wander: nil,
      wander_until: nil,
      focus_at: nil,
      remaining: waypoints,
      prev: nil,
      last: {fx, fy, 0.0}
    }

    %{state | premove: premove}
  end

  defp halt_premove(%{premove: nil} = state), do: state

  defp halt_premove(%{premove: %{wander: %Wander{}} = pm} = state) do
    {lx, ly, _} = pm.last
    settle(state, {lx, ly}, [pm.prev, pm.last])
  end

  defp halt_premove(%{premove: pm} = state) do
    {lx, ly, _} = pm.last
    LogStore.append(:step, "premove interrupted with #{length(pm.remaining)} waypoint(s) left")
    settle(state, {lx, ly}, [pm.prev, pm.last])
  end

  defp finish_premove(%{premove: %{wander: %Wander{}}} = state), do: halt_premove(state)

  defp finish_premove(%{premove: pm} = state) do
    {lx, ly, lt} = pm.last
    LogStore.append(:step, "premove still in flight, finishing it for the click")
    play_trajectory({lx, ly}, pm.remaining, lt)
    settle(state, pm.target, [pm.prev, pm.last | pm.remaining])
  end

  defp settle(state, pos, played) do
    %{state | current_pos: pos, last_velocity: terminal_velocity(Enum.reject(played, &is_nil/1)), premove: nil}
  end

  defp land(state, _x, _y, _within, _opts, 0), do: state

  defp land(state, x, y, within, opts, attempts) do
    if on_target?(start_pos(state), x, y, within) do
      :timer.sleep(Keyword.get(opts, :settle_ms, @click_settle_ms))
      state
    else
      :timer.sleep(@land_check_delay_ms)
      land_after_lag(state, x, y, within, opts, attempts)
    end
  end

  defp land_after_lag(state, x, y, within, opts, attempts) do
    pos = start_pos(state)

    if on_target?(pos, x, y, within) do
      state
    else
      LogStore.append(:step, "cursor at #{inspect(pos)} instead of (#{x}, #{y}), moving back before clicking")
      land(elem(execute_move(state, x, y, opts), 0), x, y, within, opts, attempts - 1)
    end
  end

  defp on_target?(pos, _x, _y, within) when within != nil, do: inside?(pos, within)
  defp on_target?({px, py}, x, y, nil), do: abs(px - x) <= @land_tolerance_px and abs(py - y) <= @land_tolerance_px

  defp inside?({x, y}, {bx, by, bw, bh}), do: x >= bx and x <= bx + bw and y >= by and y <= by + bh

  defp execute_move(state, tx, ty, opts) do
    state = sync(state)
    {fx, fy} = from_pos = start_pos(state)
    {vx, vy} = state.last_velocity
    profile =
      case Keyword.get(opts, :duration_override) do
        nil -> Keyword.get(opts, :duration_mult, MouseProfile.move_duration_mult())
        duration_ms -> {:duration_ms, duration_ms}
      end

    waypoints = Trajectory.build({fx * 1.0, fy * 1.0}, {tx * 1.0, ty * 1.0}, {vx, vy}, profile)

    play_trajectory(from_pos, waypoints)
    last_vel = terminal_velocity(waypoints)
    new_state = %{state | current_pos: {tx, ty}, last_velocity: last_vel}
    {new_state, waypoints}
  end

  defp absolute?, do: :persistent_term.get({__MODULE__, :absolute}, false)
  defp relative?, do: :persistent_term.get({__MODULE__, :relative}, false)

  defp sync(state) do
    relative = AppSettings.launcher() in ["gamescope", "gamescope_window", "kwin"]
    :persistent_term.put({__MODULE__, :relative}, relative)
    now = System.monotonic_time(:millisecond)

    if relative and absolute?() and resync?(state, now) do
      {x, y} = state.current_pos
      Native.move_absolute(x * 1.0, y * 1.0)
      %{state | last_move_at: now, moves_since_sync: 0}
    else
      %{state | last_move_at: now, moves_since_sync: state.moves_since_sync + 1}
    end
  end

  defp resync?(%{last_move_at: nil}, _now), do: true
  defp resync?(state, now), do: now - state.last_move_at > @resync_idle_ms or state.moves_since_sync >= @resync_every_moves

  defp step({px, py}, {wx, wy}) do
    with true <- absolute?(),
         false <- relative?(),
         :ok <- Native.move_absolute(wx * 1.0, wy * 1.0) do
      :ok
    else
      _ -> step_relative({px, py}, {wx, wy})
    end
  end

  defp step_relative({px, py}, {wx, wy}) do
    dx = wx - px
    dy = wy - py
    if abs(dx) > 0.1 or abs(dy) > 0.1, do: Native.move_relative(dx, dy)
    :ok
  end

  defp start_pos(%{current_pos: {x, y}} = state) do
    if absolute?() do
      {x * 1.0, y * 1.0}
    else
      read_cursor(state)
    end
  end

  defp read_cursor(state) do
    case Native.get_cursor_pos() do
      {:ok, x, y} ->
        {x * 1.0, y * 1.0}

      {:error, reason} ->
        Logger.warning(
          "get_cursor_pos failed (#{inspect(reason)}), falling back to tracked position",
          module: __MODULE__
        )

        state.current_pos
    end
  end

  defp play_trajectory(start_pos, waypoints, start_t \\ 0.0)
  defp play_trajectory(_prev_pos, [], _start_t), do: :ok
  defp play_trajectory(start_pos, waypoints, start_t) do
    {sx, sy} = start_pos
    Enum.reduce(waypoints, {sx * 1.0, sy * 1.0, start_t}, fn {wx, wy, t_ms}, {px, py, prev_t} ->
      step({px, py}, {wx, wy})
      delay = round(t_ms - prev_t)
      if delay > 0, do: :timer.sleep(delay)
      {wx, wy, t_ms}
    end)
    :ok
  end

  defp terminal_velocity([]), do: {0.0, 0.0}
  defp terminal_velocity(waypoints) do
    last = List.last(waypoints)
    second_last = Enum.at(waypoints, -2, last)
    {lx, ly, lt} = last
    {sx, sy, st} = second_last
    dt = max(lt - st, 1.0)
    {(lx - sx) / dt, (ly - sy) / dt}
  end

  defp do_click(button) do
    btn_code = if button == :left, do: @btn_left, else: @btn_right
    Native.button_event(btn_code, true)
    :timer.sleep(MouseProfile.click_hold_ms())
    Native.button_event(btn_code, false)
  end

  defp scroll_human(dx, dy, duration_mult) do
    steps = [dx, dy] |> Enum.map(&(&1 |> round() |> abs())) |> Enum.max() |> max(1)
    dx_per_step = dx / steps
    dy_per_step = dy / steps

    Enum.each(1..steps, fn _ ->
      scroll_units(round(dx_per_step * 120), round(dy_per_step * 120))
      :timer.sleep(round(scroll_click_delay_ms() * duration_mult))
    end)
  end

  defp scroll_units(dx_units, dy_units) do
    case Native.scroll(dx_units, dy_units) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "scroll(#{dx_units}, #{dy_units}) failed: #{inspect(reason)}",
          module: __MODULE__
        )
    end
  end

  defp scroll_click_delay_ms do
    noise = round(:rand.normal() * @scroll_click_delay_sigma)
    max(25, min(140, @scroll_click_delay_ms + noise))
  end
end
