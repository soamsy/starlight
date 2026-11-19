defmodule StarlightBotWeb.Components.WindowGate do
  use Phoenix.Component
  alias StarlightBot.GameWindow

  def gate(assigns) do
    gate(assigns[:game_window_rect], assigns[:game_launch_label], assigns[:game_launcher_missing], assigns[:game_update_pending])
  end

  def gate(rect, launch_label, launcher_missing, update_pending) do
    case rect do
      {_x, _y, _w, _h} = rect ->
        if GameWindow.aspect_ok?(rect), do: :ready, else: :resize

      _ ->
        cond do
          !(launch_label && (launcher_missing || []) == []) -> :ready
          update_pending -> :update
          true -> :launch
        end
    end
  end

  attr :gate, :atom, required: true
  attr :busy, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :class, :string, default: "btn-primary"

  def gate_button(assigns) do
    ~H"""
    <button :if={@gate == :launch} type="button" phx-click="game_window_launch" disabled={@disabled or @busy != nil} class={["btn btn-sm", @class]}>
      {if @busy, do: String.capitalize(@busy) <> "…", else: "Open Limbus"}
    </button>
    <button :if={@gate == :update} type="button" disabled class="btn btn-primary btn-sm">
      Limbus update pending
    </button>
    <button :if={@gate == :resize} type="button" phx-click="game_window_resize" disabled={@disabled or @busy != nil} class="btn btn-primary btn-sm">
      {if @busy, do: String.capitalize(@busy) <> "…", else: "Resize Limbus to 1920 × 1080"}
    </button>
    """
  end
end
