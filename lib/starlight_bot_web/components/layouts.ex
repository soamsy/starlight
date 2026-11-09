defmodule StarlightBotWeb.Layouts do
  use StarlightBotWeb, :html

  alias StarlightBotWeb.Components.{PlanPicker, TeamNav}

  embed_templates "layouts/*"

  @target_ratio 16 / 9

  def dev_js_log?, do: Application.get_env(:starlight_bot, :dev_js_log, false)

  def window_status({_x, _y, 1920, 1080}), do: :exact
  def window_status({_x, _y, w, h}) when h > 0 do
    if abs(w / h - @target_ratio) > 0.01, do: :bad_aspect, else: :scaled
  end
  def window_status(_), do: :missing

  def timeline_clock(minute), do: "#{String.pad_leading(to_string(div(minute, 60)), 2, "0")}:#{String.pad_leading(to_string(rem(minute, 60)), 2, "0")}"

  def last_charged_label(nil, _now), do: "last charged: never"

  def last_charged_label(%NaiveDateTime{} = at, %NaiveDateTime{} = now) do
    minutes = max(div(NaiveDateTime.diff(now, at, :second), 60), 0)
    "last charged: #{div(minutes, 60)}h #{rem(minutes, 60)}m ago at #{Calendar.strftime(at, "%H:%M")}"
  end

  def window_status_title(:exact), do: "Limbus window is the right size"
  def window_status_title(:scaled), do: "Limbus window is 16:9 but not 1920 × 1080"
  def window_status_title(:bad_aspect), do: "Limbus window is the wrong size"
  def window_status_title(:missing), do: "Limbus isn't open"

  def aspect_label(w, h) do
    g = Integer.gcd(w, h)
    "#{div(w, g)}:#{div(h, g)} (#{:erlang.float_to_binary(w / h, decimals: 3)})"
  end

  attr :flash, :map, required: true

  def flash_toasts(assigns) do
    ~H"""
    <div id="flash-toasts" phx-hook="Toasts">
      <%= for kind <- ["info", "error"], msg = @flash[kind] do %>
        <span hidden data-kind={kind} data-msg={msg}></span>
      <% end %>
      <div id="flash-toasts-view" phx-update="ignore"></div>
    </div>
    """
  end
end
