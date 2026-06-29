defmodule StarlightBot.Input.Mouse do
  use GenServer
  require Logger
  alias StarlightBot.{Native, Input.MovementProfile, Input.PositionSource, Input.Trajectory}

  @btn_left 0x110
  @btn_right 0x111
  @click_hold_ms 90
  @click_hold_sigma 13
  @scroll_click_delay_ms 60
  @scroll_click_delay_sigma 15

  defstruct current_pos: {960, 540}, last_velocity: {0.0, 0.0}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def move_to(x, y, opts \\ []) do
    GenServer.call(__MODULE__, {:move_to, x, y, opts}, 10_000)
  end

  def absolute_click(x, y) do
    GenServer.call(__MODULE__, {:absolute_click, x, y}, 10_000)
  end

  def visual_click(x, y) do
    GenServer.call(__MODULE__, {:visual_click, x, y}, 15_000)
  end

  def click(x, y, opts \\ []) do
    GenServer.call(__MODULE__, {:click, x, y, :left, opts}, 10_000)
  end

  def right_click(x, y, opts \\ []) do
    GenServer.call(__MODULE__, {:click, x, y, :right, opts}, 10_000)
  end

  def double_click(x, y, opts \\ []) do
    GenServer.call(__MODULE__, {:double_click, x, y, opts}, 10_000)
  end

  def drag(from, to, duration_ms \\ nil) do
    GenServer.call(__MODULE__, {:drag, from, to, duration_ms}, 15_000)
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

    case Native.init_input() do
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
  def handle_call({:move_to, x, y, opts}, _from, state) do
    {new_state, _waypoints} = execute_move(state, x, y, opts)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:absolute_click, x, y}, _from, state) do
    case Native.move_absolute(x * 1.0, y * 1.0) do
      :ok ->
        :timer.sleep(50)
        do_click(:left)
        {:reply, :ok, %{state | current_pos: {x, y}, last_velocity: {0.0, 0.0}}}

      {:error, _} ->
        {new_state, _} = execute_move(state, x, y, [])
        do_click(:left)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:visual_click, x, y}, _from, state) do
    if PositionSource.tracked?() do
      {cx, cy} = state.current_pos
      Native.move_absolute(cx * 1.0, cy * 1.0)
    end

    {new_state, _} = execute_move(state, x, y, [])
    do_click(:left)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:click, x, y, button, opts}, _from, state) do
    {new_state, _waypoints} = execute_move(state, x, y, opts)
    do_click(button)
    {:reply, :ok, new_state}
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
  def handle_call({:drag, {fx, fy}, {tx, ty}, duration_ms}, _from, state) do
    {new_state, _} = execute_move(state, fx, fy, [])
    Native.button_event(@btn_left, true)
    {final_state, _} = execute_move(new_state, tx, ty, [duration_override: duration_ms])
    Native.button_event(@btn_left, false)
    {:reply, :ok, final_state}
  end

  @impl true
  def handle_call({:button, button, pressed}, _from, state) do
    btn_code = if button == :left, do: @btn_left, else: @btn_right
    Native.button_event(btn_code, pressed)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:scroll, dx, dy}, _from, state) do
    mult = if MovementProfile.human?(), do: 1.0, else: 0.4
    scroll_human(dx, dy, mult)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:release_all, state) do
    Native.button_event(@btn_left, false)
    Native.button_event(@btn_right, false)
    Native.release_all_inputs([])
    {:noreply, %{state | last_velocity: {0.0, 0.0}}}
  end

  defp execute_move(state, tx, ty, _opts) do
    {fx, fy} = from_pos = start_pos(state)
    {vx, vy} = state.last_velocity
    profile = MovementProfile.current()

    waypoints = Trajectory.build({fx * 1.0, fy * 1.0}, {tx * 1.0, ty * 1.0}, {vx, vy}, profile)

    play_trajectory(from_pos, waypoints)
    last_vel = terminal_velocity(waypoints)
    new_state = %{state | current_pos: {tx, ty}, last_velocity: last_vel}
    {new_state, waypoints}
  end

  defp start_pos(state) do
    if PositionSource.queried?() do
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
    else
      state.current_pos
    end
  end

  defp play_trajectory(_prev_pos, []), do: :ok
  defp play_trajectory(start_pos, waypoints) do
    {sx, sy} = start_pos
    Enum.reduce(waypoints, {sx * 1.0, sy * 1.0, 0.0}, fn {wx, wy, t_ms}, {px, py, prev_t} ->
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
