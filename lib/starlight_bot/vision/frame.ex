defmodule StarlightBot.Vision.Frame do
  defstruct [:binary, :mat, :window_rect, :scale, :captured_at]

  @type t :: %__MODULE__{
    binary:       binary(),
    mat:          term(),   # Evision.Mat — BGR 1920x1080
    window_rect:  {integer(), integer(), pos_integer(), pos_integer()},
    scale:        float(),
    captured_at:  integer(),
  }

  @normalized_w 1920
  @normalized_h 1080

  def from_capture(binary, {_wx, _wy, w, _h} = window_rect)
      when is_binary(binary) do
    scale = w / @normalized_w
    mat = binary |> Evision.Mat.from_binary({:u, 8}, @normalized_h, @normalized_w, 3) |> Evision.Mat.clone()
    %__MODULE__{
      binary: binary,
      mat: mat,
      window_rect: window_rect,
      scale: scale,
      captured_at: System.monotonic_time(:millisecond),
    }
  end

  def crop(mat, {x, y, w, h}), do: Evision.getRectSubPix(mat, {w, h}, {x + (w - 1) / 2, y + (h - 1) / 2})

  def to_screen_coords(%__MODULE__{window_rect: {wx, wy, _, _}, scale: s}, {x, y}) do
    {round(wx + x * s), round(wy + y * s)}
  end

  def normalized_size, do: {@normalized_w, @normalized_h}
end
