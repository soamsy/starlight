defmodule StarlightBot.Input.Trajectory do
  @step_ms 8.0
  @step_jitter_ms 0.7
  @momentum_ms 40.0
  @momentum_cap_fraction 0.25
  @bow_median_fraction 0.09
  @bow_short_boost 0.06
  @bow_short_scale_px 200.0
  @bow_max_fraction 0.2
  @bow_sigma 0.4
  @bow_max_px 130.0
  @s_curve_fraction 0.012
  @asym_min 0.75
  @asym_max 1.3
  @drift_fraction 0.006
  @drift_max_px 4.0
  @drift_hz_min 1.2
  @drift_hz_max 3.0
  @skew_min 0.58
  @skew_max 0.68
  @tremor_amp_px 0.25
  @tremor_hz_min 8.0
  @tremor_hz_max 12.0
  @undershoot_bias 0.6
  @landing_cross_ratio 0.5
  @approach_floor 0.03
  @approach_slope 0.01
  @approach_quad 0.0004
  @approach_grid 240
  @approach_max_speedup 1.5
  @approach_softening [1.0, 1.3, 1.7, 2.2, 3.0, 4.0, 6.0, 10.0, 30.0, 1000.0]
  @approach_min_dist 30.0
  @primary_share 0.85
  @correction_start_min 0.78
  @correction_start_max 0.95

  @flat %{bow: 0.0, s_curve: 0.0, asym: 1.0, drift: 0.0, drift_hz: 2.0, drift_phase: 0.0}

  @type point :: {float, float}
  @type waypoint :: {float, float, float}

  @spec build(point, point, point, number | {:duration_ms, number}, :upper | :lower | nil) :: [waypoint]
  def build(from, to, vel_in, profile, arc \\ nil)

  def build(from, to, vel_in, {:duration_ms, duration_ms}, arc) do
    human_trajectory(from, to, vel_in, fn _dist -> duration_ms * 1.0 end, arc)
  end

  def build(from, to, vel_in, duration_mult, arc) when is_number(duration_mult) do
    human_trajectory(from, to, vel_in, &(sample_duration(&1) * duration_mult), arc)
  end

  defp human_trajectory(from, to, vel_in, base_duration, arc) do
    dist = distance(from, to)

    if dist < 1.0 do
      {tx, ty} = to
      [{tx, ty, 0.0}]
    else
      duration = base_duration.(dist)

      submovements =
        if :rand.uniform() < correction_probability(dist) do
          landing = biased_landing(from, to, landing_sigma(dist))
          primary_duration = duration * @primary_share
          start = primary_duration * (@correction_start_min + :rand.uniform() * (@correction_start_max - @correction_start_min))

          [
            submovement(from, landing, 0.0, primary_duration, shape(from, to, arc)),
            submovement(landing, to, start, corrective_duration_ms(distance(landing, to)), @flat)
          ]
        else
          [from |> submovement(to, 0.0, duration, shape(from, to, arc)) |> with_approach()]
        end

      sample(from, to, vel_in, submovements)
    end
  end

  defp submovement(from, to, start_ms, duration_ms, shape) do
    Map.merge(shape, %{from: from, to: to, start: start_ms, duration: duration_ms, skew: @skew_min + :rand.uniform() * (@skew_max - @skew_min)})
  end

  defp with_approach(%{from: from, to: to} = m) do
    dist = distance(from, to)
    if dist < @approach_min_dist, do: m, else: Map.put(m, :table, approach_table(m, dist))
  end

  defp approach_table(m, dist) do
    grid =
      for i <- 0..@approach_grid do
        tau = i / @approach_grid
        x = :math.pow(tau, m.skew)
        slope = if tau == 0.0, do: 0.0, else: 30.0 * x * x * (1.0 - x) * (1.0 - x) * m.skew * :math.pow(tau, m.skew - 1.0)
        s = min_jerk(x)
        {s, slope, approach_cap((1.0 - s) * dist) / dist}
      end

    times = fn a, soften ->
      Enum.scan(grid, {0.0, 0.0}, fn {_, slope, cap}, {_, prev} -> {0.0, prev + max(m.duration / a, slope / (cap * soften)) / @approach_grid} end)
    end

    total = fn a, soften -> times.(a, soften) |> List.last() |> elem(1) end
    soften = Enum.find(@approach_softening, List.last(@approach_softening), &(total.(@approach_max_speedup, &1) <= m.duration))
    a = bisect_speed(&total.(&1, soften), m.duration, 0.3, @approach_max_speedup, 40)
    cumulative = times.(a, soften) |> Enum.map(&elem(&1, 1))
    {List.to_tuple(cumulative), grid |> Enum.map(&elem(&1, 0)) |> List.to_tuple()}
  end

  defp bisect_speed(_total, _target, lo, hi, 0), do: (lo + hi) / 2

  defp bisect_speed(total, target, lo, hi, n) do
    mid = (lo + hi) / 2
    if total.(mid) > target, do: bisect_speed(total, target, mid, hi, n - 1), else: bisect_speed(total, target, lo, mid, n - 1)
  end

  defp approach_cap(rem_px), do: @approach_floor + @approach_slope * rem_px + @approach_quad * rem_px * rem_px

  defp table_progress({times, progress}, t) do
    last = tuple_size(times) - 1

    if t >= elem(times, last) do
      1.0
    else
      i = find_segment(times, t, 0, last)
      t0 = elem(times, i)
      t1 = elem(times, i + 1)
      s0 = elem(progress, i)
      s0 + (elem(progress, i + 1) - s0) * (t - t0) / max(t1 - t0, 1.0e-9)
    end
  end

  defp find_segment(_times, _t, lo, hi) when hi - lo <= 1, do: lo

  defp find_segment(times, t, lo, hi) do
    mid = div(lo + hi, 2)
    if elem(times, mid) <= t, do: find_segment(times, t, mid, hi), else: find_segment(times, t, lo, mid)
  end

  defp sample(from, {tx, ty} = to, vel_in, submovements) do
    total = submovements |> Enum.map(&(&1.start + &1.duration)) |> Enum.max()
    n_steps = max(2, ceil(total / @step_ms))
    tremor = new_tremor()
    {fx, fy} = from
    {mx, my} = momentum(vel_in, distance(from, to))
    primary = hd(submovements)

    times =
      0..n_steps
      |> Enum.map(fn i -> i * total / n_steps end)
      |> jitter_times()

    Enum.map(times, fn t ->
      {dx, dy} =
        Enum.reduce(submovements, {0.0, 0.0}, fn m, {ax, ay} ->
          {x, y} = displacement(m, t)
          {ax + x, ay + y}
        end)

      carry = momentum_decay(t, primary)
      {tmx, tmy} = tremor_at(tremor, t, edge_weight(t, total))
      {fx + dx + mx * carry + tmx, fy + dy + my * carry + tmy, t}
    end)
    |> List.update_at(-1, fn {_, _, t} -> {tx, ty, t} end)
  end

  defp displacement(%{from: {fx, fy}, to: {tx, ty}} = m, t) do
    tau = (t - m.start) / m.duration

    if tau <= 0.0 do
      {0.0, 0.0}
    else
      s =
        case m do
          %{table: table} -> table_progress(table, t - m.start)
          _ -> min_jerk(:math.pow(min(tau, 1.0), m.skew))
        end

      {px, py} = perpendicular({fx, fy}, {tx, ty})
      lateral =
        m.bow * :math.sin(:math.pi() * :math.pow(s, m.asym)) +
          m.s_curve * :math.sin(2.0 * :math.pi() * s) +
          m.drift * :math.sin(:math.pi() * s) * :math.sin(2.0 * :math.pi() * m.drift_hz * t / 1000.0 + m.drift_phase)
      {(tx - fx) * s + lateral * px, (ty - fy) * s + lateral * py}
    end
  end

  defp min_jerk(tau), do: tau * tau * tau * (10.0 - 15.0 * tau + 6.0 * tau * tau)

  defp momentum_decay(t, primary) do
    tau = min(t / primary.duration, 1.0)
    @momentum_ms * (1.0 - :math.exp(-t / @momentum_ms)) * (1.0 - min_jerk(tau))
  end

  defp momentum({vx, vy}, dist) do
    speed = :math.sqrt(vx * vx + vy * vy)

    if speed < 0.01 do
      {0.0, 0.0}
    else
      capped = min(speed, dist * @momentum_cap_fraction / @momentum_ms)
      {vx / speed * capped, vy / speed * capped}
    end
  end

  defp jitter_times(times) do
    last = length(times) - 1

    times
    |> Enum.with_index()
    |> Enum.map(fn
      {t, i} when i == 0 or i == last -> t
      {t, _} -> max(t + :rand.normal(0.0, @step_jitter_ms), 0.0)
    end)
    |> Enum.scan(fn t, prev -> max(t, prev + 1.0) end)
  end

  defp new_tremor do
    for _axis <- 1..2 do
      %{
        hz: @tremor_hz_min + :rand.uniform() * (@tremor_hz_max - @tremor_hz_min),
        phase: :rand.uniform() * 2 * :math.pi()
      }
    end
  end

  defp tremor_at([x, y], t_ms, weight) do
    s = t_ms / 1000.0
    amp = @tremor_amp_px * weight
    {amp * :math.sin(2 * :math.pi() * x.hz * s + x.phase), amp * :math.sin(2 * :math.pi() * y.hz * s + y.phase)}
  end

  defp edge_weight(t, total) do
    u = t / total
    min(1.0, 4.0 * min(u, 1.0 - u))
  end

  defp sample_duration(dist) do
    mu = 0.14 + 0.08 * :math.log2(1.0 + dist / 40.0)
    sigma = max(0.07, 0.13 * (1.0 - :math.exp(-dist / 350.0)))
    noise = :math.exp(:rand.normal(0.0, sigma)) |> max(0.85) |> min(1.35)
    (mu * noise) |> max(0.12) |> min(1.4) |> Kernel.*(1000.0)
  end

  @spec expected_duration_ms(number) :: float
  def expected_duration_ms(dist) do
    mu = 0.14 + 0.08 * :math.log2(1.0 + dist / 40.0)
    (mu |> max(0.12) |> min(1.4)) * 1000.0
  end

  defp corrective_duration_ms(remaining_dist) do
    (70.0 + remaining_dist * 4.0) |> min(200.0)
  end

  defp bow_fraction(dist), do: @bow_median_fraction + @bow_short_boost * :math.exp(-dist / @bow_short_scale_px)

  defp bow_sign(_from, _to, nil), do: if(:rand.uniform() < 0.5, do: -1.0, else: 1.0)

  defp bow_sign(from, to, arc) do
    {_px, py} = perpendicular(from, to)
    up = if py > 0.0, do: -1.0, else: 1.0
    if arc == :upper, do: up, else: -up
  end

  defp shape(from, to, arc) do
    dist = distance(from, to)

    %{
      bow: bow_sign(from, to, arc) * min(dist * bow_fraction(dist) * :math.exp(:rand.normal(0.0, @bow_sigma)), min(@bow_max_px, dist * @bow_max_fraction)),
      s_curve: :rand.normal(0.0, dist * @s_curve_fraction),
      asym: @asym_min + :rand.uniform() * (@asym_max - @asym_min),
      drift: min(dist * @drift_fraction, @drift_max_px),
      drift_hz: @drift_hz_min + :rand.uniform() * (@drift_hz_max - @drift_hz_min),
      drift_phase: :rand.uniform() * 2 * :math.pi()
    }
  end

  defp landing_sigma(dist), do: (dist * 0.03) |> max(1.5) |> min(12.0)
  defp correction_probability(dist), do: (dist / 600.0) |> max(0.05) |> min(0.9)

  defp biased_landing({fx, fy}, {tx, ty}, sigma) do
    {perp_x, perp_y} = perpendicular({fx, fy}, {tx, ty})
    along = :rand.normal(-@undershoot_bias * sigma, sigma)
    cross = :rand.normal(0.0, sigma * @landing_cross_ratio)
    chord = distance({fx, fy}, {tx, ty})
    {ux, uy} = {(tx - fx) / chord, (ty - fy) / chord}
    {tx + along * ux + cross * perp_x, ty + along * uy + cross * perp_y}
  end

  defp distance({x0, y0}, {x1, y1}) do
    :math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))
  end

  defp perpendicular({fx, fy}, {tx, ty}) do
    chord_len = max(distance({fx, fy}, {tx, ty}), 1.0e-6)
    {-(ty - fy) / chord_len, (tx - fx) / chord_len}
  end
end
