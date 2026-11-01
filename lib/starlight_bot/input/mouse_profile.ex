defmodule StarlightBot.Input.MouseProfile do
  @move_duration_mult 0.7
  @scroll_delay_mult 0.4
  @click_hold_ms 40

  def move_duration_mult, do: @move_duration_mult * personality().tempo
  def scroll_delay_mult, do: @scroll_delay_mult * personality().tempo
  def click_hold_ms, do: @click_hold_ms

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
    mean = personality().hesitation_ms
    (mean + :rand.normal() * mean * 0.35) |> round() |> max(0)
  end

  def reroll do
    :persistent_term.put({__MODULE__, :personality}, roll())
  end

  defp roll do
    %{
      tempo: between(0.85, 1.2),
      hesitation_ms: between(10.0, 90.0),
      rest: {between(0.5, 0.85), between(0.45, 0.8)},
      idle_span: {between(0.3, 0.5), between(0.3, 0.5)},
      scroll_burst: Enum.random(2..5),
      scroll_burst_pause_ms: between(60.0, 200.0)
    }
  end

  defp between(lo, hi), do: lo + :rand.uniform() * (hi - lo)
end
