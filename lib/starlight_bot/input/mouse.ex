defmodule StarlightBot.Input.Mouse do
  use GenServer
  require Logger
  alias StarlightBot.{AppSettings, LogStore, Native, Input.Dwell, Input.MouseProfile, Input.Trajectory, Input.Wander, Vision.Capture}

  @btn_left 0x110
  @btn_right 0x111
  @scroll_click_delay_ms 60
  @scroll_click_delay_sigma 15
  @drag_settle_ms 100
  @mouse_down_settle_ms 5
  @release_settle_ms 50
  @click_settle_ms 65
  @dwell_jitter_px 15
  @min_hover_ms 70
  @land_check_delay_ms 5
  @land_tolerance_px 3
  @land_attempts 3
  @wander_max_ms 60_000
  @wander_tick_ms 12
  @wander_focus_check_ms 250
  @anchor_ttl_ms 15_000
  @fitts_ref_width_px 50.0
  @resync_idle_ms 60_000
  @resync_every_moves 25

  defstruct current_pos: {960, 540}, last_velocity: {0.0, 0.0}, held: MapSet.new(), premove: nil, anchor: nil, last_move_at: nil, moves_since_sync: 0

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def move_to(x, y, opts \\ []) do
    GenServer.call(__MODULE__, {:move_to, x, y, opts}, 10_000)
  end

  def dwell(ms, opts \\ []) do
    GenServer.call(__MODULE__, {:dwell, ms, opts}, ms + 5_000)
  end

  def premove(x, y, within) do
    GenServer.cast(__MODULE__, {:premove, x, y, within})
  end

  def idle do
    GenServer.cast(__MODULE__, :idle)
  end

  def halt_wander do
    GenServer.cast(__MODULE__, :halt_wander)
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

  def handle_call({:button, button, true}, _from, %{premove: %{wander: %Wander{}, within: within} = pm} = state) when within != nil do
    Native.button_event(button_code(button), true)
    {lx, ly, _} = pm.last
    now = System.monotonic_time(:millisecond)

    pm =
      case Wander.area(within, Capture.window_rect(), 0.0) do
        nil -> pm
        area -> %{pm | wander: Wander.new(area, {lx, ly}, [held: true] ++ wander_opts()), wander_until: now + @wander_max_ms}
      end

    {:reply, :ok, %{state | held: MapSet.put(state.held, button), premove: pm}}
  end

  def handle_call(msg, from, %{premove: %{}} = state) do
    handle_call(msg, from, halt_premove(state))
  end

  def handle_call({:move_to, x, y, opts}, _from, state) do
    {new_state, _waypoints} = execute_move(state, x, y, opts)
    {:reply, :ok, new_state}
  end

  def handle_call({:dwell, ms, opts}, _from, state) do
    pos = Dwell.run(ms, state.current_pos, Keyword.get(opts, :jitter_px, @dwell_jitter_px), &step/2)
    {:reply, :ok, %{state | current_pos: pos}}
  end

  @impl true
  def handle_call({:click, x, y, button, opts}, _from, state) do
    within = Keyword.get(opts, :within)

    new_state = state |> execute_move(x, y, opts) |> elem(0)
    new_state = land(new_state, x, y, within, opts, @land_attempts)

    pos = hover(max(MouseProfile.hesitation_ms(), @min_hover_ms), new_state.current_pos)
    do_click(button)
    {:reply, :ok, %{new_state | current_pos: pos}}
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
    :timer.sleep(MouseProfile.double_click_gap_ms())
    do_click(:left)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:drag, {fx, fy}, {tx, ty}, opts}, _from, state) do
    {new_state, _} = execute_move(state, fx, fy, [])
    hover(Keyword.get(opts, :settle_ms, @drag_settle_ms), {fx, fy})
    Native.button_event(@btn_left, true)
    hover(Keyword.get(opts, :mouse_down_settle_ms, @mouse_down_settle_ms), {fx, fy})
    {final_state, _} = execute_move(new_state, tx, ty, [duration_override: Keyword.get(opts, :duration_ms)])
    pos = hover(Keyword.get(opts, :release_settle_ms, @release_settle_ms), {tx, ty})
    Native.button_event(@btn_left, false)
    {:reply, :ok, %{final_state | current_pos: pos}}
  end

  @impl true
  def handle_call({:button, button, pressed}, _from, state) do
    Native.button_event(button_code(button), pressed)
    held = if pressed, do: MapSet.put(state.held, button), else: MapSet.delete(state.held, button)
    {:reply, :ok, %{state | held: held}}
  end

  @impl true
  def handle_call({:scroll, dx, dy}, _from, state) do
    state = ensure_in_anchor(state)
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

  def handle_cast(:halt_wander, state), do: {:noreply, halt_premove(state)}

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

      [{wx, wy, _t} = waypoint | rest] ->
        {px, py, _} = pm.last
        step({px, py}, {wx, wy})
        Process.send_after(self(), {:premove_tick, ref}, next_tick_delay(pm.started, rest, System.monotonic_time(:millisecond)))
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
      if abs(wx - lx) > 0.05 or abs(wy - ly) > 0.05, do: step({lx, ly}, {wx, wy})
      Process.send_after(self(), {:wander_tick, ref}, @wander_tick_ms)
      focus_at = if now - pm.focus_at >= @wander_focus_check_ms, do: now, else: pm.focus_at
      {:noreply, %{state | premove: %{pm | wander: wander, prev: pm.last, last: {wx, wy, now}, focus_at: focus_at}}}
    else
      {:noreply, halt_premove(state)}
    end
  end

  def handle_info({:wander_tick, _stale_ref}, state), do: {:noreply, state}

  defp next_tick_delay(_started, [], _now), do: 0
  defp next_tick_delay(started, [{_, _, t} | _], now), do: max(round(started + t - now), 0)

  defp still_focused(pm, now), do: now - pm.focus_at < @wander_focus_check_ms or game_focused?()

  defp game_focused? do
    match?({:ok, true}, Native.is_window_focused(Application.get_env(:starlight_bot, :game_window_class, "LimbusCompany")))
  end

  defp targets?(%{target: nil}, _within), do: false
  defp targets?(%{target: target}, within), do: inside?(target, within)

  defp begin_wander(%{area: nil} = pm), do: pm

  defp begin_wander(pm) do
    {lx, ly, _} = pm.last
    now = System.monotonic_time(:millisecond)
    send(self(), {:wander_tick, pm.ref})
    %{pm | wander: Wander.new(pm.area, {lx, ly}, wander_opts()), wander_until: now + @wander_max_ms, focus_at: now, prev: nil, last: {lx, ly, now}}
  end

  defp start_premove(state, tx, ty, within) do
    state = sync(state)
    {fx, fy} = start_pos(state)

    waypoints =
      if inside?({fx, fy}, within),
        do: [],
        else:
          Trajectory.build(
            {fx * 1.0, fy * 1.0},
            {tx * 1.0, ty * 1.0},
            state.last_velocity,
            MouseProfile.move_duration_mult() * fitts_mult({fx, fy}, {tx, ty}, within)
          )

    area = Wander.area(within, Capture.window_rect())
    begin_premove(state, {tx, ty}, within, waypoints, {fx * 1.0, fy * 1.0}, area, :premove)
  end

  defp start_idle(state) do
    state = sync(state)
    {fx, fy} = start_pos(state)
    window = Capture.window_rect()

    area =
      case fresh_anchor(state) do
        nil -> Wander.zone(window, MouseProfile.personality().rest, MouseProfile.personality().idle_span)
        box -> Wander.area(box, window, 0.0)
      end

    case area do
      nil ->
        state

      area ->
        waypoints =
          if Wander.inside?({fx, fy}, area),
            do: [],
            else: Trajectory.build({fx * 1.0, fy * 1.0}, Wander.random_point(area), state.last_velocity, MouseProfile.move_duration_mult())

        begin_premove(state, nil, nil, waypoints, {fx * 1.0, fy * 1.0}, area, :idle)
    end
  end

  defp begin_premove(state, target, within, waypoints, {fx, fy}, area, kind) do
    ref = make_ref()
    send(self(), {:premove_tick, ref})

    premove = %{
      ref: ref,
      kind: kind,
      target: target,
      within: within,
      area: area,
      wander: nil,
      wander_until: nil,
      focus_at: nil,
      remaining: waypoints,
      started: System.monotonic_time(:millisecond),
      prev: nil,
      last: {fx, fy, 0.0}
    }

    %{state | premove: premove, anchor: if(kind == :idle, do: state.anchor)}
  end

  defp wander_opts, do: [tempo: 1.0 / MouseProfile.personality().tempo]

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

  defp hover(ms, {x, y}), do: Dwell.run(ms, {x, y}, @dwell_jitter_px, &step/2)

  defp land(state, _x, _y, _within, _opts, 0), do: state

  defp land(state, x, y, within, opts, attempts) do
    if on_target?(start_pos(state), x, y, within) do
      hover(Keyword.get(opts, :settle_ms, @click_settle_ms), {x, y})
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
        nil -> Keyword.get(opts, :duration_mult, MouseProfile.move_duration_mult()) * fitts_mult(from_pos, {tx, ty}, Keyword.get(opts, :within))
        duration_ms -> {:duration_ms, duration_ms}
      end

    waypoints = Trajectory.build({fx * 1.0, fy * 1.0}, {tx * 1.0, ty * 1.0}, {vx, vy}, profile, Keyword.get(opts, :arc))

    play_trajectory(from_pos, waypoints)
    last_vel = terminal_velocity(waypoints)
    new_state = %{state | current_pos: {tx, ty}, last_velocity: last_vel, anchor: anchor_from(opts)}
    {new_state, waypoints}
  end

  defp fitts_mult(_from, _to, nil), do: 1.0

  defp fitts_mult({fx, fy}, {tx, ty}, {_bx, _by, bw, bh}) do
    dist = :math.sqrt((tx - fx) * (tx - fx) + (ty - fy) * (ty - fy))
    width = max(min(bw, bh), 8.0)
    ratio = (1.0 + :math.log2(1.0 + dist / width)) / (1.0 + :math.log2(1.0 + dist / @fitts_ref_width_px))
    ratio |> max(0.8) |> min(1.4)
  end

  defp anchor_from(opts) do
    case Keyword.get(opts, :anchor) do
      nil -> nil
      box -> {box, System.monotonic_time(:millisecond)}
    end
  end

  defp fresh_anchor(%{anchor: {box, at}}) do
    if System.monotonic_time(:millisecond) - at <= @anchor_ttl_ms, do: box
  end

  defp fresh_anchor(_state), do: nil

  defp ensure_in_anchor(state) do
    with box when box != nil <- fresh_anchor(state),
         {bx, by, bw, bh} = box,
         false <- inside?(start_pos(state), box) do
      {tx, ty} = {bx + :rand.uniform() * bw, by + :rand.uniform() * bh}
      LogStore.append(:step, "scroll: cursor left the scroll area, moving back before scrolling")
      elem(execute_move(state, tx, ty, anchor: box), 0)
    else
      _ -> state
    end
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
    started = System.monotonic_time(:millisecond)
    Enum.reduce(waypoints, {sx * 1.0, sy * 1.0}, fn {wx, wy, t_ms}, {px, py} ->
      delay = round(started + t_ms - start_t - System.monotonic_time(:millisecond))
      if delay > 0, do: :timer.sleep(delay)
      step({px, py}, {wx, wy})
      {wx, wy}
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

  defp button_code(:left), do: @btn_left
  defp button_code(_button), do: @btn_right

  defp do_click(button) do
    btn_code = button_code(button)
    Native.button_event(btn_code, true)
    :timer.sleep(MouseProfile.click_hold_ms())
    Native.button_event(btn_code, false)
  end

  defp scroll_human(dx, dy, duration_mult) do
    steps = [dx, dy] |> Enum.map(&(&1 |> round() |> abs())) |> Enum.max() |> max(1)
    scroll_bursts(steps, round(dx / steps * 120), round(dy / steps * 120), duration_mult)
  end

  defp scroll_bursts(0, _dx_units, _dy_units, _duration_mult), do: :ok

  defp scroll_bursts(remaining, dx_units, dy_units, duration_mult) do
    profile = MouseProfile.personality()
    burst = min(remaining, max(1, profile.scroll_burst + Enum.random(-1..1)))
    burst_mult = duration_mult * (0.75 + :rand.uniform() * 0.6)

    Enum.each(1..burst, fn _ ->
      scroll_units(dx_units, dy_units)
      :timer.sleep(round(scroll_click_delay_ms() * burst_mult))
    end)

    if remaining > burst, do: :timer.sleep(round(profile.scroll_burst_pause_ms * (0.7 + :rand.uniform() * 0.8)))
    scroll_bursts(remaining - burst, dx_units, dy_units, duration_mult)
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
