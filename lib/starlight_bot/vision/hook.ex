defmodule StarlightBot.Vision.Hook do
  @type match_method :: :rgb | :gray | :edge | :akaze | :sift | :binary_thresh | :color_detector | :grayscale_detector

  @enforce_keys [:name, :mat, :gray_mat, :method, :confidence]
  defstruct [
    :name,           # atom
    :mat,            # Evision.Mat — BGR, loaded from images table
    :gray_mat,       # Evision.Mat — grayscale version, precomputed at load time
    :region,         # nil | {x, y, w, h} — crop the template was captured from;
                      # also the default search crop when scan_region is nil
    :click_region,   # nil | {x, y, w, h} — target for click automation; nil = use match center
    :scan_region,    # nil | {x, y, w, h} — when set, search this (larger) area for
                      # the template instead of assuming it's exactly at `region`.
                      # Matching itself is unchanged (matchTemplate already does a
                      # sliding-window search); this only changes which crop gets searched.
                      # Ignored entirely for :color_detector hooks (always searches `region`).
    :mask,           # boolean — when true, black template pixels are excluded from
                      # matching (see mask_mat)
    :mask_mat,       # nil | Evision.Mat — precomputed at load time when mask is true;
                      # single-channel 0/255 mask (255 = non-black, counts toward the
                      # match score; 0 = black, ignored regardless of what the target
                      # frame shows there). Passed as matchTemplate's `mask:` option.
    :color,          # nil | {h, s, v} — OpenCV HSV scale (h: 0-179, s/v: 0-255).
                      # Only used by :color_detector hooks.
    :min_cluster_size, # nil | integer — minimum pixel-area of a color cluster to
                      # count as detected. Defined for a 1920×1080 frame; scaled down
                      # proportionally when matched against a smaller-resolution
                      # capture. Only used by :color_detector hooks.
    :method,         # match_method()
    :confidence,     # float 0.0–1.0
    :notes,
    :source,         # :user | :master
    :keypoints,
    :descriptors,
  ]

  @color_bgr2gray 6  # cv_COLOR_BGR2GRAY
  @thresh_binary  0  # cv_THRESH_BINARY
  @mask_black_threshold 10  # grayscale value below which a template pixel counts as "black"

  def from_db_row(row) do
    tmp = "/tmp/_starlight_hook_load.png"
    File.write!(tmp, row.image)
    mat = Evision.imread(tmp)
    gray_mat = Evision.cvtColor(mat, @color_bgr2gray)
    mask? = truthy?(row.mask)
    mask_mat = if(mask?, do: build_mask(gray_mat), else: nil)
    method = decode_match_method(row.match_method)
    {keypoints, descriptors} = compute_keypoints_descriptors(method, gray_mat, mask_mat)

    %__MODULE__{
      name: String.to_atom(row.name),
      mat: mat,
      gray_mat: gray_mat,
      region: decode_region(row),
      click_region: decode_click_region(row),
      scan_region: decode_scan_region(row),
      mask: mask?,
      mask_mat: mask_mat,
      color: decode_color(row),
      min_cluster_size: Map.get(row, :min_cluster_size),
      method: method,
      confidence: row.confidence,
      notes: row.notes,
      source: :user,
      keypoints: keypoints,
      descriptors: descriptors,
    }
  end

  defp truthy?("true"), do: true
  defp truthy?(true), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp build_mask(gray_mat) do
    {_, mask} = Evision.threshold(gray_mat, @mask_black_threshold, 255, @thresh_binary)
    mask
  end

  defp compute_keypoints_descriptors(:sift, gray_mat, mask_mat) do
    Evision.SIFT.detectAndCompute(Evision.SIFT.create(), gray_mat, mask_mat || Evision.Mat.empty())
  end

  defp compute_keypoints_descriptors(:akaze, gray_mat, mask_mat) do
    Evision.XFeatures2D.AKAZE.detectAndCompute(Evision.XFeatures2D.AKAZE.create(), gray_mat, mask_mat || Evision.Mat.empty())
  end

  defp compute_keypoints_descriptors(_method, _gray_mat, _mask_mat), do: {nil, nil}

  defp decode_match_method("rgb"), do: :rgb
  defp decode_match_method("gray"), do: :gray
  defp decode_match_method("edge"), do: :edge
  defp decode_match_method("akaze"), do: :akaze
  defp decode_match_method("sift"), do: :sift
  defp decode_match_method("binary_thresh"), do: :binary_thresh
  defp decode_match_method("color_detector"), do: :color_detector
  defp decode_match_method("grayscale_detector"), do: :grayscale_detector
  defp decode_match_method(other), do: raise(ArgumentError, "unknown match_method: #{inspect(other)}")

  defp decode_region(%{region_x: x, region_y: y, region_w: w, region_h: h})
       when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h),
       do: {x, y, w, h}
  defp decode_region(_), do: nil

  defp decode_click_region(%{click_x: x, click_y: y, click_w: w, click_h: h})
       when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h),
       do: {x, y, w, h}
  defp decode_click_region(_), do: nil

  defp decode_scan_region(%{scan_x: x, scan_y: y, scan_w: w, scan_h: h})
       when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h),
       do: {x, y, w, h}
  defp decode_scan_region(_), do: nil

  defp decode_color(%{color_h: h, color_s: s, color_v: v})
       when is_integer(h) and is_integer(s) and is_integer(v),
       do: {h, s, v}
  defp decode_color(_), do: nil
end
