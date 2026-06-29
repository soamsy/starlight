defmodule StarlightBot.Input.PositionSource do
  @moduledoc """
  Controls where Input.Mouse gets a trajectory's starting position from.

  :queried — ask the compositor for the actual cursor position before each
             move, via KWin's D-Bus scripting bridge (Native.get_cursor_pos/0).
             Correct even if something else (the user's hand) moved the
             cursor between bot actions. KDE/KWin only; falls back to
             :tracked behavior for that one call if the query fails.
  :tracked — use the internally tracked last-known position (pre-existing
             behavior). Works on any compositor but drifts from reality if
             anything else moves the cursor between moves.

  Toggled at runtime; persists only for the current session.
  """

  @type t :: :queried | :tracked

  def current do
    Application.get_env(:starlight_bot, :position_source, :queried)
  end

  def set(source) when source in [:queried, :tracked] do
    Application.put_env(:starlight_bot, :position_source, source)
  end

  def queried?, do: current() == :queried
  def tracked?, do: current() == :tracked
end
