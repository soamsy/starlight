defmodule StarlightBot.HardwareTest do

  use ExUnit.Case, async: false

  @moduletag :kde

  setup_all do
    if live_kde_session?() do
      :ok
    else
      {:skip, "no live KDE/Wayland session detected (XDG_SESSION_TYPE/XDG_CURRENT_DESKTOP) — " <>
                "run this on a machine with KDE Plasma 6.0+ up"}
    end
  end

  test "Native.init_input/0 connects to KWin's EIS interface" do
    assert :ok = StarlightBot.Native.init_input()
  end

  test "Native.get_cursor_pos/0 round-trips through the KWin scripting D-Bus bridge" do
    assert {:ok, x, y} = StarlightBot.Native.get_cursor_pos()
    assert is_number(x)
    assert is_number(y)
  end

  defp live_kde_session? do
    System.get_env("XDG_SESSION_TYPE") == "wayland" and
      (String.contains?(System.get_env("XDG_CURRENT_DESKTOP") || "", "KDE") or
         System.get_env("KDE_FULL_SESSION") != nil)
  end
end
