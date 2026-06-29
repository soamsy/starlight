defmodule StarlightBot.Input.MovementProfile do

  @type t :: :human | :fast

  def current do
    Application.get_env(:starlight_bot, :movement_profile, :human)
  end

  def set(profile) when profile in [:human, :fast] do
    Application.put_env(:starlight_bot, :movement_profile, profile)
  end

  def human?, do: current() == :human
  def fast?, do: current() == :fast
end
