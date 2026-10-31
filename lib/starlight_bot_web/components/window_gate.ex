defmodule StarlightBotWeb.Components.WindowGate do
  use Phoenix.Component
  alias StarlightBot.GameWindow

  def gate(assigns) do
    case assigns[:game_window_rect] do
      {_x, _y, _w, _h} = rect ->
        if GameWindow.aspect_ok?(rect), do: :ready, else: :resize

      _ ->
        if assigns[:game_launch_label] && (assigns[:game_launcher_missing] || []) == [], do: :launch, else: :ready
    end
  end

  attr :gate, :atom, required: true
  attr :busy, :string, default: nil
  attr :disabled, :boolean, default: false

  def gate_button(assigns) do
    ~H"""
    <button :if={@gate == :launch} type="submit" disabled={@disabled or @busy != nil} class="btn btn-primary btn-sm">
      {if @busy, do: String.capitalize(@busy) <> "…", else: "Open Limbus and run"}
    </button>
    <button :if={@gate == :resize} type="button" phx-click="game_window_resize" disabled={@disabled or @busy != nil} class="btn btn-primary btn-sm">
      {if @busy, do: String.capitalize(@busy) <> "…", else: "Resize Limbus to 1920 × 1080"}
    </button>
    """
  end
end
