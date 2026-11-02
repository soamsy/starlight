defmodule StarlightBot.Input.MouseProfile do
  @move_duration_mult 0.55
  @scroll_delay_mult 0.4
  @drift_decay 0.97
  @drift_sigma 0.02
  @drift_limit 0.15
  @long_pause_chance 0.02

  def move_duration_mult, do: @move_duration_mult * personality().tempo * advance_drift()
  def scroll_delay_mult, do: @scroll_delay_mult * personality().tempo

  def click_hold_ms do
    personality().click_hold_ms |> lognormal(0.25) |> round() |> max(45) |> min(180)
  end

  def double_click_gap_ms do
    personality().double_click_gap_ms |> lognormal(0.3) |> round() |> max(50) |> min(180)
  end

  def personality do
    case :persistent_term.get({__MODULE__, :personality}, nil) do
      nil ->
        rolled = roll()
        :persistent_term.put({__MODULE__, :personality}, rolled)
        rolled

      rolled ->
        rolled
    end
  end

  def hesitation_ms do
    base = personality().hesitation_ms |> lognormal(0.5) |> round()
    if :rand.uniform() < @long_pause_chance, do: base + round(400.0 + :rand.uniform() * 1100.0), else: base
  end

  def reroll do
    :persistent_term.put({__MODULE__, :personality}, roll())
  end

  defp roll do
    %{
      tempo: between(0.85, 1.2),
      hesitation_ms: between(10.0, 90.0),
      click_hold_ms: between(65.0, 105.0),
      double_click_gap_ms: between(70.0, 110.0),
      rest: {between(0.5, 0.85), between(0.45, 0.8)},
      idle_span: {between(0.3, 0.5), between(0.3, 0.5)},
      scroll_burst: Enum.random(2..5),
      scroll_burst_pause_ms: between(60.0, 200.0)
    }
  end

  defp advance_drift do
    drift =
      (:persistent_term.get({__MODULE__, :drift}, 0.0) * @drift_decay + :rand.normal() * @drift_sigma)
      |> max(-@drift_limit)
      |> min(@drift_limit)

    :persistent_term.put({__MODULE__, :drift}, drift)
    1.0 + drift
  end

  defp lognormal(median, sigma), do: median * :math.exp(:rand.normal() * sigma)

  defp between(lo, hi), do: lo + :rand.uniform() * (hi - lo)
end
