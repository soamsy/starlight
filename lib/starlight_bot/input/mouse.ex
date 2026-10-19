defmodule StarlightBot.Input.Mouse do
  use GenServer
  require Logger
  alias StarlightBot.{LogStore, Native, Input.MovementProfile, Input.Trajectory}

  @btn_left 0x110
  @btn_right 0x111
  @click_hold_ms 90
  @click_hold_sigma 13
  @scroll_click_delay_ms 60
  @scroll_click_delay_sigma 15
  @drag_settle_ms 50
  @mouse_down_settle_ms 30
  @click_settle_ms 0

  defstruct current_pos: {960, 540}, last_velocity: {0.0, 0.0}, held: MapSet.new(), premove: nil

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def move_to(x, y, opts \\ []) do
    GenServer.call(__MODULE__, {:move_to, x, y, opts}, 10_000)
  end

  def premove(x, y, within) do
    GenServer.cast(__MODULE__, {:premove, x, y, within})
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
    Logger.info("Input.Mouse starting — initializing EIS connection", module: __MODULE__)

    case Native.init_input(Application.get_env(:starlight_bot, :game_window_title, "LimbusCompany")) do
      :ok ->
        Logger.info("EIS input device ready", module: __MODULE__)
      {:error, reason} ->
        Logger.error(
          "EIS input initialization failed: #{inspect(reason)}. " <>
          "Verify KWin EIS D-Bus interface is available (Plasma 6.0+). " <>
          "Input injection will not work.",
          module: __MODULE__
        )
    end

    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:click, _x, _y, _button, opts} = msg, from, %{premove: %{} = pm} = state) do
    state =
      case Keyword.get(opts, :within) do
        nil -> halt_premove(state)
        within -> if inside?(pm.target, within), do: finish_premove(state), else: halt_premove(state)
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
        LogStore.append(:info, "premove: cursor already on target, clicking in place")
        state
      else
        elem(execute_move(state, x, y, opts), 0)
      end
    :timer.sleep(Keyword.get(opts, :settle_ms, @click_settle_ms))

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
    mult = if MovementProfile.human?(), do: 1.0, else: 0.4
    scroll_human(dx, dy, mult)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:premove, x, y, within}, state) do
    cond do
      MapSet.size(state.held) > 0 ->
        LogStore.append(:info, "premove skipped: mouse button held")
        {:noreply, state}

      state.premove != nil and inside?(state.premove.target, within) ->
        {:noreply, state}

      true ->
        state = halt_premove(state)

        if inside?(start_pos(state), within) do
          {:noreply, state}
        else
          {:noreply, start_premove(state, x, y)}
        end
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
        {:noreply, settle(state, pm.target, [pm.prev, pm.last])}

      [{wx, wy, t} = waypoint | rest] ->
        {px, py, prev_t} = pm.last
        dx = wx - px
        dy = wy - py
        if abs(dx) > 0.1 or abs(dy) > 0.1, do: Native.move_relative(dx, dy)
        Process.send_after(self(), {:premove_tick, ref}, max(round(t - prev_t), 0))
        {:noreply, %{state | premove: %{pm | remaining: rest, prev: pm.last, last: waypoint}}}
    end
  end

  def handle_info({:premove_tick, _stale_ref}, state), do: {:noreply, state}

  defp start_premove(state, tx, ty) do
    {fx, fy} = start_pos(state)
    waypoints = Trajectory.build({fx * 1.0, fy * 1.0}, {tx * 1.0, ty * 1.0}, state.last_velocity, MovementProfile.current())
    ref = make_ref()
    send(self(), {:premove_tick, ref})

    %{state | premove: %{ref: ref, target: {tx, ty}, remaining: waypoints, prev: nil, last: {fx * 1.0, fy * 1.0, 0.0}}}
  end

  defp halt_premove(%{premove: nil} = state), do: state

  defp halt_premove(%{premove: pm} = state) do
    {lx, ly, _} = pm.last
    LogStore.append(:info, "premove interrupted with #{length(pm.remaining)} waypoint(s) left")
    settle(state, {lx, ly}, [pm.prev, pm.last])
  end

  defp finish_premove(%{premove: pm} = state) do
    {lx, ly, lt} = pm.last
    LogStore.append(:info, "premove still in flight, finishing it for the click")
    play_trajectory({lx, ly}, pm.remaining, lt)
    settle(state, pm.target, [pm.prev, pm.last | pm.remaining])
  end

  defp settle(state, pos, played) do
    %{state | current_pos: pos, last_velocity: terminal_velocity(Enum.reject(played, &is_nil/1)), premove: nil}
  end

  defp inside?({x, y}, {bx, by, bw, bh}), do: x >= bx and x <= bx + bw and y >= by and y <= by + bh

  defp execute_move(state, tx, ty, opts) do
    {fx, fy} = from_pos = start_pos(state)
    {vx, vy} = state.last_velocity
    profile = Keyword.get(opts, :duration_mult, MovementProfile.current())

    waypoints = Trajectory.build({fx * 1.0, fy * 1.0}, {tx * 1.0, ty * 1.0}, {vx, vy}, profile)

    play_trajectory(from_pos, waypoints)
    last_vel = terminal_velocity(waypoints)
    new_state = %{state | current_pos: {tx, ty}, last_velocity: last_vel}
    {new_state, waypoints}
  end

  defp start_pos(state) do
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
      dx = wx - px
      dy = wy - py
      if abs(dx) > 0.1 or abs(dy) > 0.1 do
        Native.move_relative(dx, dy)
      end
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
    hold_ms = click_hold_ms()
    Native.button_event(btn_code, true)
    :timer.sleep(hold_ms)
    Native.button_event(btn_code, false)
  end

  defp click_hold_ms do
    if MovementProfile.human?() do
      noise = round(:rand.normal() * @click_hold_sigma)
      max(38, min(220, @click_hold_ms + noise))
    else
      30
    end
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
