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

  attr :flash, :map, required: true

  def flash_toasts(assigns) do
    ~H"""
    <%= if msg = @flash["info"] do %>
      <div class="fixed bottom-4 left-1/2 -translate-x-1/2 z-50 flex items-center gap-2 px-3 py-2 rounded-lg shadow-md bg-success/90 text-success-content text-xs cursor-pointer select-none"
           role="alert"
           phx-click="lv:clear-flash" phx-value-key="info">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7" />
        </svg>
        <span><%= msg %></span>
      </div>
    <% end %>

    <%= if msg = @flash["error"] do %>
      <div class="fixed bottom-4 left-1/2 -translate-x-1/2 z-50 flex items-center gap-2 px-3 py-2 rounded-lg shadow-md bg-error/90 text-error-content text-xs cursor-pointer select-none"
           role="alert"
           phx-click="lv:clear-flash" phx-value-key="error">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
        </svg>
        <span><%= msg %></span>
      </div>
    <% end %>
    """
  end
end
