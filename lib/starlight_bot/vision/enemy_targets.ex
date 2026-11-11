defmodule StarlightBot.Vision.EnemyTargets do
  alias StarlightBot.Vision.Frame

  @region {546, 112, 1180, 660}
  @window 64
  @stride 8
  @scales [1.15, 1.0, 0.85, 0.76, 0.69, 0.63, 0.55]
  @suppress_px 45
  @threshold 0.4
  @descriptor_size 1764
  @model_file "priv/vision/enemy_targets_hog.f32"
  @color_bgr2gray 6
  @interpolation_area 3

  defstruct [:point, :icon, :zone]

  @type t :: %__MODULE__{point: {number, number}, icon: {number, number}, zone: {number, number, number, number} | nil}

  @spec find(Frame.t(), number) :: [t()]
  def find(%Frame{} = frame, threshold \\ @threshold) do
    frame
    |> gray()
    |> candidates(detector(), threshold)
    |> suppress()
    |> Enum.map(&to_target/1)
    |> Enum.sort_by(fn %__MODULE__{point: {x, _y}} -> x end)
  end

  def region, do: @region
  def window, do: @window
  def stride, do: @stride
  def scales, do: @scales
  def threshold, do: @threshold
  def descriptor_size, do: @descriptor_size
  def model_path, do: Application.app_dir(:starlight_bot, @model_file)

  def gray(%Frame{} = frame), do: frame |> Frame.region(@region) |> Evision.cvtColor(@color_bgr2gray)

  def pyramid(gray), do: Enum.map(@scales, fn scale -> {scale, Evision.resize(gray, {0, 0}, fx: scale, fy: scale, interpolation: @interpolation_area)} end)

  def candidates(gray, hog, threshold) do
    {region_x, region_y, _w, _h} = @region

    gray
    |> pyramid()
    |> Enum.flat_map(fn {scale, resized} ->
      {locations, weights} = Evision.HOGDescriptor.detect(hog, resized, hitThreshold: threshold, winStride: {@stride, @stride}, padding: {0, 0})
      Enum.zip_with(locations, weights, fn {x, y}, score -> {(x + @window / 2) / scale + region_x, (y + @window / 2) / scale + region_y, score} end)
    end)
  end

  def suppress(candidates) do
    candidates
    |> Enum.sort_by(fn {_x, _y, score} -> -score end)
    |> Enum.reduce([], fn {x, y, _score} = candidate, kept ->
      if Enum.any?(kept, fn {kx, ky, _} -> :math.sqrt((x - kx) ** 2 + (y - ky) ** 2) <= @suppress_px end), do: kept, else: [candidate | kept]
    end)
    |> Enum.reverse()
  end

  def new_hog do
    [winSize: {@window, @window}, blockSize: {16, 16}, blockStride: {@stride, @stride}, cellSize: {8, 8}, nbins: 9]
    |> :evision_nif.hogDescriptor_HOGDescriptor()
    |> Evision.HOGDescriptor.to_struct()
  end

  def build_detector(model) when byte_size(model) == (@descriptor_size + 1) * 4 do
    mat = Evision.Mat.from_binary(model, {:f, 32}, 1, @descriptor_size + 1, 1)
    Evision.HOGDescriptor.setSVMDetector(new_hog(), mat)
  end

  def detector do
    case :persistent_term.get({__MODULE__, :detector}, nil) do
      nil ->
        detector = model_path() |> File.read!() |> build_detector()
        :persistent_term.put({__MODULE__, :detector}, detector)
        detector

      detector ->
        detector
    end
  end

  def reload_detector, do: :persistent_term.erase({__MODULE__, :detector})

  defp to_target({x, y, _score}) do
    point = {round(x), round(y)}
    %__MODULE__{point: point, icon: point, zone: nil}
  end
end
