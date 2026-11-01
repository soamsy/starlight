defmodule StarlightBot.Input.Wander do
  alias StarlightBot.Input.Trajectory

  @margin 15.0
  @active_s 5.0
  @sweep_median_s 0.7
  @sweep_sigma 0.5
  @sweep_min_s 0.25
  @sweep_max_s 3.0
  @amp_min_px 4.0
  @amp_max_px 12.0
  @held_amp_min_px 1.0
  @held_amp_max_px 2.5
  @held_twitch_hz 0.4
  @held_twitch_median_px 2.0
  @held_twitch_max_px 4.0
  @spring_hz_min 1.2
  @spring_hz_max 2.2
  @spring_zeta 0.3
  @settle_tau_s 0.25
  @lunge_median_px 90.0
  @lunge_sigma 0.6
  @lunge_min_px 35.0
  @lunge_max_px 260.0
  @lunge_area_fraction 0.6
  @lunge_base_ms 110.0
  @lunge_ms_per_px 0.75
  @lunge_offset_tau_s 0.05
  @tremor_hz_min 8.0
  @tremor_hz_max 12.0
  @tremor_amp_min_px 0.15
  @tremor_amp_max_px 0.4
  @active_twitch_hz 0.8
  @active_twitch_median_px 6.0
  @still_twitch_hz 0.45
  @still_twitch_median_px 3.5
  @twitch_sigma 0.4
  @twitch_min_px 1.5
  @twitch_max_px 16.0
  @twitch_tau_s 0.04
  @twitch_decay_s 0.3
  @max_dt_s 0.05

  defstruct [
    :area,
    :opts,
    :anchor,
    :lunge,
    :spring,
    :tremor,
    mode: :sweep,
    sweep_left: 0.0,
    age: 0.0,
    off: {0.0, 0.0},
    vel: {0.0, 0.0},
    kick: {0.0, 0.0},
    kick_goal: {0.0, 0.0},
    pos: {0.0, 0.0}
  ]

  def margin, do: @margin

  def window_inset(nil), do: nil
  def window_inset({wx, wy, ww, wh}), do: {wx + @margin, wy + @margin, wx + ww - @margin, wy + wh - @margin}

  def area(within, window, margin \\ @margin) do
    screen = window_inset(window)

    case within do
      nil -> screen
      {bx, by, bw, bh} -> intersect({bx - margin, by - margin, bx + bw + margin, by + bh + margin}, screen)
    end
  end

  def zone(nil, _rest, _span), do: nil

  def zone(window, {fx, fy}, {sx, sy}) do
    {x0, y0, x1, y1} = window_inset(window)
    hw = (x1 - x0) * sx / 2
    hh = (y1 - y0) * sy / 2
    cx = clamp(x0 + (x1 - x0) * fx, x0 + hw, x1 - hw)
    cy = clamp(y0 + (y1 - y0) * fy, y0 + hh, y1 - hh)
    {cx - hw, cy - hh, cx + hw, cy + hh}
  end

  def random_point({x0, y0, x1, y1}), do: {x0 + :rand.uniform() * (x1 - x0), y0 + :rand.uniform() * (y1 - y0)}

  def inside?({x, y}, {x0, y0, x1, y1}), do: x >= x0 and x <= x1 and y >= y0 and y <= y1


  def new({x0, y0, x1, y1} = area, {px, py}, opts \\ []) do
    start = {clamp(px, x0, x1), clamp(py, y0, y1)}

    %__MODULE__{area: area, opts: opts, anchor: start, pos: start, tremor: new_tremor()}
    |> begin_sweep()
  end

  def active_s, do: @active_s

  def step(%__MODULE__{} = w, dt_s) do
    dt = min(dt_s, @max_dt_s)
    w = %{w | age: w.age + dt}
    w = if w.age >= @active_s and w.mode == :sweep, do: %{w | mode: :still}, else: w
    w = w |> advance(dt) |> twitch(dt)
    {ax, ay} = w.anchor
    {ox, oy} = w.off
    {kx, ky} = w.kick
    {tx, ty} = if w.mode == :sweep, do: tremor_at(w.tremor, w.age), else: {0.0, 0.0}
    {x0, y0, x1, y1} = w.area
    %{w | pos: {clamp(ax + ox + kx + tx, x0, x1), clamp(ay + oy + ky + ty, y0, y1)}}
  end

  defp advance(%{mode: :sweep} = w, dt) do
    w = spring(w, dt)
    w = %{w | sweep_left: w.sweep_left - dt}
    cond do
      w.sweep_left > 0.0 -> w
      held?(w) -> begin_sweep(w)
      true -> begin_lunge(w)
    end
  end

  defp advance(%{mode: :still} = w, dt) do
    decay = :math.exp(-dt / @settle_tau_s)
    {ox, oy} = w.off
    {vx, vy} = w.vel
    %{w | off: {ox * decay, oy * decay}, vel: {vx * decay, vy * decay}}
  end

  defp advance(%{mode: :lunge, lunge: l} = w, dt) do
    t = l.t + dt * 1000.0
    decay = :math.exp(-dt / @lunge_offset_tau_s)
    {ox, oy} = w.off

    if t >= l.dur do
      mode = if w.age >= @active_s, do: :still, else: :sweep
      %{w | anchor: l.to, lunge: nil, off: {0.0, 0.0}, vel: {0.0, 0.0}, mode: mode} |> begin_sweep()
    else
      %{w | anchor: waypoint_at(l.waypoints, t), lunge: %{l | t: t}, off: {ox * decay, oy * decay}}
    end
  end

  defp spring(%{spring: sp, off: {x, y}, vel: {vx, vy}} = w, dt) do
    accel = fn p, v -> -sp.omega * sp.omega * p - 2.0 * sp.zeta * sp.omega * v end
    noise = sp.sigma * :math.sqrt(dt)
    vx = vx + accel.(x, vx) * dt + noise * :rand.normal()
    vy = vy + accel.(y, vy) * dt + noise * :rand.normal()
    %{w | off: {x + vx * dt, y + vy * dt}, vel: {vx, vy}}
  end

  defp begin_sweep(w) do
    tempo = Keyword.get(w.opts, :tempo, 1.0)
    {amp_min, amp_max} = if held?(w), do: {@held_amp_min_px, @held_amp_max_px}, else: {@amp_min_px, @amp_max_px}
    amp = amp_min + :rand.uniform() * (amp_max - amp_min)
    omega = 2.0 * :math.pi() * (@spring_hz_min + :rand.uniform() * (@spring_hz_max - @spring_hz_min)) * tempo
    sigma = :math.sqrt(4.0 * @spring_zeta * omega * omega * omega) * amp
    sweep_s = lognormal(@sweep_median_s, @sweep_sigma) |> clamp(@sweep_min_s, @sweep_max_s)
    %{w | mode: if(w.mode == :still, do: :still, else: :sweep), spring: %{omega: omega, zeta: @spring_zeta, sigma: sigma}, sweep_left: sweep_s}
  end

  defp begin_lunge(w) do
    tempo = Keyword.get(w.opts, :tempo, 1.0)
    {x0, y0, x1, y1} = w.area
    diag = distance({x0, y0}, {x1, y1})
    max_px = min(@lunge_max_px, @lunge_area_fraction * diag)
    min_px = min(@lunge_min_px, max_px / 2)
    {ax, ay} = w.anchor
    {ox, oy} = w.off
    from = {clamp(ax + ox, x0, x1), clamp(ay + oy, y0, y1)}
    dist = lognormal(@lunge_median_px, @lunge_sigma) |> clamp(min_px, max_px)
    angle = :rand.uniform() * 2 * :math.pi()
    {fx, fy} = from
    to = {clamp(fx + dist * :math.cos(angle), x0, x1), clamp(fy + dist * :math.sin(angle), y0, y1)}
    real = distance(from, to)
    dur = (@lunge_base_ms + @lunge_ms_per_px * real) / tempo
    {vx, vy} = w.vel
    waypoints = Trajectory.build(from, to, {vx / 1000.0, vy / 1000.0}, {:duration_ms, dur})
    {_, _, last_t} = List.last(waypoints)
    %{w | mode: :lunge, lunge: %{waypoints: waypoints, t: 0.0, dur: last_t, to: elem_xy(List.last(waypoints))}, anchor: from, off: {0.0, 0.0}}
  end

  defp elem_xy({x, y, _t}), do: {x, y}

  defp waypoint_at([{x, y, _}], _t), do: {x, y}

  defp waypoint_at([{x0, y0, t0}, {x1, y1, t1} | rest], t) do
    if t >= t1 do
      waypoint_at([{x1, y1, t1} | rest], t)
    else
      u = if t1 > t0, do: (t - t0) / (t1 - t0), else: 1.0
      {x0 + (x1 - x0) * u, y0 + (y1 - y0) * u}
    end
  end

  defp new_tremor do
    for _axis <- 1..2 do
      %{
        hz: @tremor_hz_min + :rand.uniform() * (@tremor_hz_max - @tremor_hz_min),
        amp: @tremor_amp_min_px + :rand.uniform() * (@tremor_amp_max_px - @tremor_amp_min_px),
        phase: :rand.uniform() * 2 * :math.pi()
      }
    end
  end

  defp tremor_at([x, y], age) do
    {x.amp * :math.sin(2 * :math.pi() * x.hz * age + x.phase), y.amp * :math.sin(2 * :math.pi() * y.hz * age + y.phase)}
  end

  defp twitch(%{kick: {kx, ky}, kick_goal: {gx, gy}} = w, dt) do
    {hz, median, max_px} =
      cond do
        held?(w) -> {@held_twitch_hz, @held_twitch_median_px, @held_twitch_max_px}
        w.mode == :sweep -> {@active_twitch_hz, @active_twitch_median_px, @twitch_max_px}
        true -> {@still_twitch_hz, @still_twitch_median_px, @twitch_max_px}
      end

    {gx, gy} =
      if w.mode != :lunge and :rand.uniform() < dt * hz do
        angle = :rand.uniform() * 2 * :math.pi()
        mag = lognormal(median, @twitch_sigma) |> clamp(min(@twitch_min_px, max_px), max_px)
        {gx + mag * :math.cos(angle), gy + mag * :math.sin(angle)}
      else
        {gx, gy}
      end

    follow = 1.0 - :math.exp(-dt / @twitch_tau_s)
    decay = :math.exp(-dt / @twitch_decay_s)
    %{w | kick: {kx + (gx - kx) * follow, ky + (gy - ky) * follow}, kick_goal: {gx * decay, gy * decay}}
  end

  defp held?(w), do: Keyword.get(w.opts, :held, false)

  defp lognormal(median, sigma), do: median * :math.exp(:rand.normal() * sigma)

  defp distance({ax, ay}, {bx, by}), do: :math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by))

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp intersect(box, nil), do: box

  defp intersect({ax0, ay0, ax1, ay1}, {bx0, by0, bx1, by1} = screen) do
    x0 = max(ax0, bx0)
    y0 = max(ay0, by0)
    x1 = min(ax1, bx1)
    y1 = min(ay1, by1)
    if x1 > x0 and y1 > y0, do: {x0, y0, x1, y1}, else: screen
  end
end
