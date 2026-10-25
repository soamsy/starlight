defmodule StarlightBot.Input.MouseProfile do
  @move_duration_mult 0.65
  @scroll_delay_mult 0.4
  @click_hold_ms 40

  def move_duration_mult, do: @move_duration_mult
  def scroll_delay_mult, do: @scroll_delay_mult
  def click_hold_ms, do: @click_hold_ms
end
