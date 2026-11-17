defmodule StarlightBot.Vision.ProfileScan do
  alias StarlightBot.Vision.{HookRegistry, Frame}

  @color_bgr2gray 6
  @tm_ccoeff_normed 5
  @interp_area 3
  @interp_cubic 2

  @type scale_hit :: %{scale: float, score: float, rect: {integer, integer, integer, integer}}
  @type result :: %{hook: String.t(), per_scale: [scale_hit], best: scale_hit | nil, template_size: {integer, integer}, confidence: float}

  def scales(min, _max, steps) when steps <= 1, do: [min]

  def scales(min, max, steps) do
    ratio = max / min
    for i <- 0..(steps - 1), do: Float.round(min * :math.pow(ratio, i / (steps - 1)), 3)
  end

  @spec run(Evision.Mat.t(), {integer, integer, integer, integer}, [String.t()], [float]) :: [result]
  def run(mat, {rx, ry, rw, rh}, hook_names, scales) do
    gray = mat |> Frame.crop({rx, ry, rw, rh}) |> Evision.cvtColor(@color_bgr2gray)
    loaded = Map.new(HookRegistry.all_names(), &{Atom.to_string(&1), &1})

    hook_names
    |> Enum.uniq()
    |> Task.async_stream(&scan_hook(&1, loaded, gray, {rx, ry}, scales), max_concurrency: System.schedulers_online(), timeout: :infinity)
    |> Enum.flat_map(fn {:ok, result} -> List.wrap(result) end)
  end

  defp scan_hook(name, loaded, gray, offset, scales) do
    with atom when not is_nil(atom) <- loaded[name], {:ok, hook} <- HookRegistry.find(atom) do
      {tw, th} = template_size(hook.gray_mat)
      per_scale = Enum.flat_map(scales, &match_at(gray, hook.gray_mat, {tw, th}, &1, offset))
      %{hook: name, per_scale: per_scale, best: Enum.max_by(per_scale, & &1.score, fn -> nil end), template_size: {tw, th}, confidence: hook.confidence}
    else
      _ -> nil
    end
  end

  defp match_at(gray, template, {tw, th}, scale, {ox, oy}) do
    {rh, rw} = shape(gray)
    w = max(round(tw * scale), 1)
    h = max(round(th * scale), 1)

    if w > rw or h > rh or w < 4 or h < 4 do
      []
    else
      interp = if scale < 1, do: @interp_area, else: @interp_cubic
      resized = if w == tw and h == th, do: template, else: Evision.resize(template, {w, h}, interpolation: interp)
      {_min, max, _min_loc, {x, y}} = gray |> Evision.matchTemplate(resized, @tm_ccoeff_normed) |> Evision.minMaxLoc()
      [%{scale: scale, score: max, rect: {x + ox, y + oy, w, h}}]
    end
  end

  defp template_size(mat) do
    {h, w} = shape(mat)
    {w, h}
  end

  defp shape(mat) do
    case Evision.Mat.shape(mat) do
      {h, w} -> {h, w}
      {h, w, _c} -> {h, w}
    end
  end
end
