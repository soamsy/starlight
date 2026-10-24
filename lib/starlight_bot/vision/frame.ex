defmodule StarlightBot.Vision.Frame do
  defstruct [:binary, :mat, :window_rect, :scale, :captured_at, patches: []]

  @type t :: %__MODULE__{
    binary:       binary(),
    mat:          term(),   # Evision.Mat — BGR 1920x1080
    window_rect:  {integer(), integer(), pos_integer(), pos_integer()},
    scale:        float(),
    captured_at:  integer(),
    patches:      [{{integer(), integer(), pos_integer(), pos_integer()}, term()}],
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

  def from_patches(patches, {_wx, _wy, w, _h} = window_rect) do
    %__MODULE__{
      patches: patches,
      window_rect: window_rect,
      scale: w / @normalized_w,
      captured_at: System.monotonic_time(:millisecond),
    }
  end

  def full?(%__MODULE__{mat: mat}), do: mat != nil

  def covers?(%__MODULE__{mat: nil, patches: patches}, rects), do: Enum.all?(rects, &patch_for(patches, &1))
  def covers?(%__MODULE__{}, _rects), do: true

  def region(%__MODULE__{mat: nil, patches: patches}, {x, y, w, h} = rect) do
    case patch_for(patches, rect) do
      {^rect, mat} -> mat
      {{px, py, _, _}, mat} -> crop(mat, {x - px, y - py, w, h})
      nil -> raise ArgumentError, "frame has no patch covering #{inspect(rect)}"
    end
  end

  def region(%__MODULE__{mat: mat}, rect), do: crop(mat, rect)

  defp patch_for(patches, {x, y, w, h}) do
    Enum.find(patches, fn {{px, py, pw, ph}, _mat} -> x >= px and y >= py and x + w <= px + pw and y + h <= py + ph end)
  end

  def crop(mat, {x, y, w, h}), do: Evision.getRectSubPix(mat, {w, h}, {x + (w - 1) / 2, y + (h - 1) / 2})

  def to_screen_coords(%__MODULE__{window_rect: {wx, wy, _, _}, scale: s}, {x, y}) do
    {round(wx + x * s), round(wy + y * s)}
  end

  def normalized_size, do: {@normalized_w, @normalized_h}
end
