defmodule StarlightBotWeb.Components.Icon do
  use Phoenix.Component

  attr :name, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def icon(%{name: "lucide-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" {@rest}></span>
    """
  end
end
