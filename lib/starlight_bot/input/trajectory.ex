defmodule StarlightBot.Input.Trajectory do
  @jitter_sigma 1.5
  @corrective_jitter_sigma 0.6
  @jitter_phi 0.65
  @bow_bias_fraction 1.58
  @primary_t_peak 0.42
  @momentum_carry_ms 40.0
  @momentum_carry_fraction_cap 0.25
  @wobble_amp_scale 2.00
  @wobble_amp_max 150.0
  @wobble_knot_span 40.0
  @wobble_max_interior_knots 8

  @type point :: {float, float}
  @type waypoint :: {float, float, float}

  @spec build(point, point, point, :human | :fast) :: [waypoint]
  def build(from, to, vel_in, profile) do
    duration_mult = if profile == :fast, do: 1.8, else: 3.6
    human_trajectory(from, to, vel_in, duration_mult)
  end

  defp human_trajectory(from, to, vel_in, duration_mult) do
    dist = distance(from, to)

    cond do
      dist < 1.0 ->
        {tx, ty} = to
        [{tx, ty, 0.0}]

      :rand.uniform() < correction_probability(dist) ->
        build_two_phase(from, to, vel_in, dist, duration_mult)

      true ->
        build_single_phase(from, to, vel_in, dist, duration_mult)
    end
  end

  defp build_single_phase(from, to, vel_in, dist, duration_mult) do
    duration_ms = sample_duration(dist) * duration_mult

    draw_curve(from, to, vel_in, duration_ms, @jitter_sigma, 1.0, @primary_t_peak)
    |> force_exact_end(to)
  end

  defp build_two_phase(from, to, vel_in, dist, duration_mult) do
    landing = biased_landing(to, overshoot_sigma(dist))
    primary_duration = sample_duration(dist) * duration_mult * 0.82

    primary = draw_curve(from, landing, vel_in, primary_duration, @jitter_sigma, 1.0, @primary_t_peak)

    {lx, ly, _} = List.last(primary)
    pause = pause_ms()
    pause_wp = {lx, ly, primary_duration + pause}

    remaining = distance({lx, ly}, to)
    corrective_duration = corrective_duration_ms(remaining)
    carry_vel = terminal_velocity(primary)

    corrective =
      draw_curve({lx, ly}, to, carry_vel, corrective_duration, @corrective_jitter_sigma, 0.4, 0.5)
      |> offset_time(primary_duration + pause)
      |> force_exact_end(to)

    primary ++ [pause_wp] ++ corrective
  end

  defp draw_curve(from, to, vel_in, duration_ms, jitter_sigma, bow_scale, t_peak) do
    dist = distance(from, to)
    n_controls = if dist < 200.0, do: 1, else: 2
    perp_std = dist * 0.12 * bow_scale
    controls = sample_control_points(from, to, vel_in, n_controls, perp_std)

    n_steps = max(2, ceil(duration_ms / 8.0))
    jitter_x = correlated_jitter(n_steps + 1, jitter_sigma, @jitter_phi)
    jitter_y = correlated_jitter(n_steps + 1, jitter_sigma, @jitter_phi)
    {perp_x, perp_y} = perpendicular(from, to)
    wobble = wobble_knots(dist)

    0..n_steps
    |> Enum.zip(Enum.zip(jitter_x, jitter_y))
    |> Enum.map(fn {i, {jx, jy}} ->
      t = i / n_steps
      ease_t = ease_asymmetric(t, t_peak)
      {x, y} = bezier_point(from, to, controls, ease_t)
      w = wobble_at(wobble, ease_t)
      {x + jx + w * perp_x, y + jy + w * perp_y, t * duration_ms}
    end)
  end

  defp wobble_knots(dist) do
    sigma = min(dist * @wobble_amp_scale, @wobble_amp_max)
    n_interior = 1 + min(@wobble_max_interior_knots, trunc(dist / @wobble_knot_span))

    interior =
      for i <- 1..n_interior do
        t = i / (n_interior + 1)
        {t, :rand.normal(0.0, sigma) * :math.sin(:math.pi() * t)}
      end

    [{0.0, 0.0}] ++ interior ++ [{1.0, 0.0}]
  end

  defp wobble_at(knots, t) do
    [{t0, v0}, {t1, v1}] =
      knots
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find(fn [{a, _}, {b, _}] -> t >= a and t <= b end)

    if t1 == t0, do: v0, else: v0 + (v1 - v0) * (t - t0) / (t1 - t0)
  end

  defp sample_duration(dist) do
    mu = 0.1 + 0.28 * :math.log2(1.0 + (dist + 80.0) / 50.0)
    sigma = max(0.07, 0.13 * (1.0 - :math.exp(-dist / 350.0)))

    noise = :math.exp(:rand.normal(0.0, sigma))
    duration_s = (mu * noise) |> max(0.35) |> min(2.0)
    duration_s * 1000.0 / 5.0
  end

  defp corrective_duration_ms(remaining_dist) do
    (60.0 + remaining_dist * 3.0) |> max(60.0) |> min(220.0)
  end

  defp pause_ms, do: 30.0 + :rand.uniform() * 50.0

  defp overshoot_sigma(dist), do: (dist * 0.025) |> max(1.5) |> min(14.0)
  defp correction_probability(dist), do: (dist / 600.0) |> max(0.05) |> min(0.9)

  defp sample_control_points({fx, fy}, {tx, ty}, vel_in, n, perp_std) do
    chord_len = distance({fx, fy}, {tx, ty})
    {perp_x, perp_y} = perpendicular({fx, fy}, {tx, ty})
    {mx, my} = momentum_offset(vel_in, chord_len)
    bias = perp_std * @bow_bias_fraction

    for i <- 0..(n - 1) do
      t = if n == 1, do: 0.5, else: 0.3 + 0.4 * (i / max(n - 1, 1))
      base_x = fx + t * (tx - fx)
      base_y = fy + t * (ty - fy)
      offset = bias + :rand.normal(0.0, perp_std)
      cx = base_x + offset * perp_x
      cy = base_y + offset * perp_y

      if i == 0, do: {cx + mx, cy + my}, else: {cx, cy}
    end
  end

  defp momentum_offset({vx, vy}, dist) do
    speed = :math.sqrt(vx * vx + vy * vy)

    if speed < 0.01 do
      {0.0, 0.0}
    else
      carry = min(speed * @momentum_carry_ms, dist * @momentum_carry_fraction_cap)
      {vx / speed * carry, vy / speed * carry}
    end
  end

  @doc false
  def bezier_point(from, to, controls, t) do
    [from | controls]
    |> Kernel.++([to])
    |> de_casteljau(t)
  end

  defp de_casteljau([point], _t), do: point

  defp de_casteljau(points, t) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{x0, y0}, {x1, y1}] -> {x0 + t * (x1 - x0), y0 + t * (y1 - y0)} end)
    |> de_casteljau(t)
  end

  defp ease_asymmetric(t, t_peak), do: t |> warp_time(t_peak) |> ease_in_out_cubic()

  defp warp_time(t, t_peak) when t < t_peak, do: 0.5 * t / t_peak
  defp warp_time(t, t_peak), do: 0.5 + 0.5 * (t - t_peak) / (1.0 - t_peak)

  defp ease_in_out_cubic(t) when t < 0.5, do: 4.0 * t * t * t
  defp ease_in_out_cubic(t), do: 1.0 - :math.pow(-2.0 * t + 2.0, 3) / 2.0

  defp biased_landing({tx, ty}, sigma) do
    {tx + :rand.normal(0.0, sigma), ty + :rand.normal(0.0, sigma)}
  end

  defp correlated_jitter(n, sigma, _phi) when n <= 1, do: [:rand.normal(0.0, sigma)]

  defp correlated_jitter(n, sigma, phi) do
    eps_sigma = sigma * :math.sqrt(max(1.0 - phi * phi, 0.0001))
    seed = :rand.normal(0.0, sigma)

    1..(n - 1)
    |> Enum.reduce([seed], fn _, [prev | _] = acc -> [phi * prev + :rand.normal(0.0, eps_sigma) | acc] end)
    |> Enum.reverse()
  end

  defp offset_time(waypoints, offset_ms) do
    Enum.map(waypoints, fn {x, y, t} -> {x, y, t + offset_ms} end)
  end

  defp force_exact_end(waypoints, {ex, ey}) do
    List.update_at(waypoints, -1, fn {_, _, t} -> {ex, ey, t} end)
  end

  defp terminal_velocity(waypoints) do
    case Enum.slice(waypoints, -2, 2) do
      [{x0, y0, t0}, {x1, y1, t1}] ->
        dt = max(t1 - t0, 1.0)
        {(x1 - x0) / dt, (y1 - y0) / dt}

      _ ->
        {0.0, 0.0}
    end
  end

  defp distance({x0, y0}, {x1, y1}) do
    :math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))
  end

  defp perpendicular({fx, fy}, {tx, ty}) do
    chord_len = distance({fx, fy}, {tx, ty})
    {-(ty - fy) / chord_len, (tx - fx) / chord_len}
  end
end
