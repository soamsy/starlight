defmodule StarlightBot.Input.Premove do

  @type t :: :off | :on

  def current do
    Application.get_env(:starlight_bot, :premove, :on)
  end

  def set(mode) when mode in [:off, :on] do
    Application.put_env(:starlight_bot, :premove, mode)
  end

  def enabled?, do: current() == :on
end
