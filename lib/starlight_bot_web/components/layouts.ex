defmodule StarlightBotWeb.Layouts do
  use StarlightBotWeb, :html

  embed_templates "layouts/*"

  @target_ratio 16 / 9

  def bad_window_size?({_x, _y, w, h}) when h > 0, do: abs(w / h - @target_ratio) > 0.01
  def bad_window_size?(_), do: false

  def aspect_label(w, h) do
    g = Integer.gcd(w, h)
    "#{div(w, g)}:#{div(h, g)} (#{:erlang.float_to_binary(w / h, decimals: 3)})"
  end
end
