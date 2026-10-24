defmodule StarlightBot.Native do
  @moduledoc """
  Rustler NIF wrapper for starlight_native.

  All NIF functions panic with :nif_not_loaded if the native library hasn't compiled yet.
  On first `mix compile`, Rustler compiles the Rust crate automatically.
  """

  use Rustler, otp_app: :starlight_bot, crate: "starlight_native"

  # --- Capture ---

  @doc "Capture the game window by title. Returns {:ok, binary, width, height} or {:error, atom}."
  def grab_frame(_window_title), do: nif_err()

  @doc "Capture only a region of the game window (region coords in 1920×1080 space). Returns {:ok, binary, w, h} or {:error, atom}."
  def grab_frame_region(_window_title, _rx, _ry, _rw, _rh), do: nif_err()

  @doc "Capture several regions of the game window in one batch (coords in 1920×1080 space). Returns {:ok, [binary]} in the order given, each rw×rh BGR, or {:error, atom}."
  def grab_regions(_window_title, _rects), do: nif_err()

  @doc "Capture the game window at its native resolution, no resize to 1920×1080. Returns {:ok, binary, width, height} or {:error, atom}."
  def grab_frame_raw(_window_title), do: nif_err()

  @doc "Save raw BGR binary as PNG. Returns :ok or {:error, reason_string}."
  def save_png(_bgr_binary, _width, _height, _path), do: nif_err()

  @doc """
  Query window absolute position via kdotool subprocess.
  Returns {:ok, wx, wy, w, h} or {:error, atom}.
  """
  def get_window_rect(_class_name), do: nif_err()

  @doc """
  Whether the window currently has OS input focus (reads _NET_ACTIVE_WINDOW).
  Deliberately uncached — call this right before injecting input, not on a
  timer, so it reflects focus state at that exact moment.
  Returns {:ok, boolean} or {:error, atom}.
  """
  def is_window_focused(_class_name), do: nif_err()

  # --- Input ---

  @doc """
  Initialize the libei EIS client for whichever display the game window is on.
  Locates `window_title` across every X display first: if it's on a nested
  display (not the host `$DISPLAY`), connects to that nested KWin's EIS over
  `$XDG_RUNTIME_DIR/starlight-nested/bus`; otherwise uses `LIBEI_SOCKET`, then
  the RemoteDesktop portal. If the game isn't running yet, connects to the host;
  input calls reconnect automatically once the game is found on another display.
  Must be called once at startup before any input functions.
  Returns :ok or {:error, reason_atom}.
  """
  def init_input(_window_title), do: nif_err()

  @doc "Inject relative mouse motion (screen pixels). Returns :ok or {:error, atom}."
  def move_relative(_dx, _dy), do: nif_err()

  @doc "Inject mouse button event. code: 0x110=left, 0x111=right, 0x112=middle. Returns :ok or {:error, atom}."
  def button_event(_code, _pressed), do: nif_err()

  @doc "Inject keyboard key event. keycode: evdev code (ESC=1, ENTER=28, SPACE=57, P=25). Returns :ok or {:error, atom}."
  def key_event(_keycode, _pressed), do: nif_err()

  @doc """
  Inject a discrete (wheel-click) scroll event. dx/dy in units of 120 per wheel
  click (ei_scroll.scroll_discrete convention); positive dy scrolls down.
  Returns :ok or {:error, atom}.
  """
  def scroll(_dx, _dy), do: nif_err()

  @doc "Release all held buttons and specified keys. Safe to call when uncertain of state."
  def release_all_inputs(_held_keycodes), do: nif_err()

  @doc """
  Query the actual compositor cursor position via KWin scripting D-Bus bridge (KDE only).
  Round trip is ~5-30ms — call once per mouse move, not per frame.
  Returns {:ok, x, y} or {:error, atom}.
  """
  def get_cursor_pos(), do: nif_err()

  defp nif_err, do: :erlang.nif_error(:nif_not_loaded)
end
