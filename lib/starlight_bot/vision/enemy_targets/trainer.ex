defmodule StarlightBot.Vision.EnemyTargets.Trainer do
  alias StarlightBot.BattleDebug
  alias StarlightBot.BattleDebug.Verify
  alias StarlightBot.Vision.EnemyTargets

  @fill_px 58
  @jitter_px [-4, 0, 4]
  @random_per_scale 300
  @hard_per_scale 150
  @mine_floor -0.3
  @away_px 38
  @mining_rounds 2
  @positive_weight 8.0
  @lambda 0.3
  @folds 5
  @eval_floor 0.0
  @eval_thresholds [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8]
  @cholesky 3
  @transpose_first 1

  def lambda, do: @lambda

  def suite_frames do
    hog = EnemyTargets.new_hog()

    BattleDebug.list()
    |> Enum.filter(&(&1["kind"] == "focused_enemies" and &1["in_suite?"]))
    |> Enum.flat_map(fn %{"id" => id} = record ->
      case BattleDebug.load_frame(id) do
        {:ok, frame} -> [prepare(hog, id, EnemyTargets.gray(frame), BattleDebug.truth(id, record)["rects"])]
        :error -> []
      end
    end)
  end

  def fit(frames, lambda \\ @lambda), do: fit(frames, lambda, Enum.map(frames, & &1.sums) |> sum_all(), @mining_rounds)

  def cross_validate(frames, lambda \\ @lambda) do
    frames
    |> Enum.with_index()
    |> Enum.group_by(fn {_frame, index} -> rem(index, @folds) end, fn {frame, _index} -> frame end)
    |> Map.values()
    |> Task.async_stream(
      fn held ->
        held_ids = Enum.map(held, & &1.id)
        model = frames |> Enum.reject(&(&1.id in held_ids)) |> fit(lambda)
        evaluate(model, held)
      end,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.flat_map(fn {:ok, rows} -> rows end)
    |> Enum.sort_by(& &1.id)
  end

  def evaluate(model, frames) do
    detector = EnemyTargets.build_detector(model)

    Enum.flat_map(frames, fn frame ->
      candidates = EnemyTargets.candidates(frame.gray, detector, @eval_floor)

      for threshold <- @eval_thresholds do
        points = candidates |> Enum.filter(fn {_x, _y, score} -> score >= threshold end) |> EnemyTargets.suppress() |> Enum.map(fn {x, y, _} -> %{"x" => round(x), "y" => round(y)} end)
        result = Verify.compare("focused_enemies", %{"rects" => frame.rects}, %{"enemies" => points})
        %{id: frame.id, threshold: threshold, ok?: result.ok?, missed: length(result.missed), extra: length(result.extra), boxes: length(frame.rects)}
      end
    end)
  end

  def write_model(model) do
    path = Path.expand("priv/vision/enemy_targets_hog.f32")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, model)
    EnemyTargets.reload_detector()
    path
  end

  defp prepare(hog, id, gray, rects) do
    {region_x, region_y, _w, _h} = EnemyTargets.region()
    centers = Enum.map(rects, fn r -> {r["x"] + r["w"] / 2 - region_x, r["y"] + r["h"] / 2 - region_y, (r["w"] + r["h"]) / 2} end)
    pyramid = EnemyTargets.pyramid(gray)

    sums =
      [
        sums(positives(hog, pyramid, centers), 1.0, @positive_weight),
        sums(random_negatives(hog, pyramid, centers), -1.0, 1.0)
      ]
      |> sum_all()

    %{id: id, gray: gray, rects: rects, centers: centers, pyramid: pyramid, sums: sums}
  end

  defp positives(hog, pyramid, centers) do
    half = EnemyTargets.window() / 2

    for {cx, cy, size} <- centers,
        {scale, mat} <- nearby_scales(pyramid, size),
        dx <- @jitter_px,
        dy <- @jitter_px,
        x = round(cx * scale - half) + dx,
        y = round(cy * scale - half) + dy,
        fits?(mat, x, y) do
      descriptor(hog, mat, x, y)
    end
  end

  defp nearby_scales(pyramid, size) do
    best = pyramid |> Enum.with_index() |> Enum.min_by(fn {{scale, _mat}, _i} -> abs(@fill_px / scale - size) end) |> elem(1)
    Enum.slice(pyramid, max(best - 1, 0)..min(best + 1, length(pyramid) - 1)//1)
  end

  defp random_negatives(hog, pyramid, centers) do
    Enum.flat_map(pyramid, fn {scale, mat} ->
      mat
      |> grid()
      |> Enum.reject(&near_truth?(&1, scale, centers))
      |> Enum.take_random(@random_per_scale)
      |> Enum.map(fn {x, y} -> descriptor(hog, mat, x, y) end)
    end)
  end

  defp hard_negatives(detector, frame) do
    Enum.flat_map(frame.pyramid, fn {scale, mat} ->
      {locations, _weights} =
        Evision.HOGDescriptor.detect(detector, mat, hitThreshold: @mine_floor, winStride: {EnemyTargets.stride(), EnemyTargets.stride()}, padding: {0, 0})

      locations
      |> Enum.reject(&near_truth?(&1, scale, frame.centers))
      |> Enum.take_random(@hard_per_scale)
      |> Enum.map(fn {x, y} -> descriptor(detector, mat, x, y) end)
    end)
  end

  defp grid(mat) do
    {height, width} = {elem(mat.shape, 0), elem(mat.shape, 1)}
    window = EnemyTargets.window()
    for y <- 0..(height - window)//EnemyTargets.stride(), x <- 0..(width - window)//EnemyTargets.stride(), do: {x, y}
  end

  defp near_truth?({x, y}, scale, centers) do
    half = EnemyTargets.window() / 2
    Enum.any?(centers, fn {cx, cy, _} -> :math.sqrt(((x + half) / scale - cx) ** 2 + ((y + half) / scale - cy) ** 2) <= @away_px end)
  end

  defp fits?(mat, x, y) do
    window = EnemyTargets.window()
    x >= 0 and y >= 0 and x + window <= elem(mat.shape, 1) and y + window <= elem(mat.shape, 0)
  end

  defp descriptor(hog, mat, x, y) do
    window = EnemyTargets.window()
    hog |> Evision.HOGDescriptor.compute(Evision.Mat.roi(mat, {x, y, window, window})) |> Enum.map_join(&<<&1::float-32-native>>)
  end

  defp fit(frames, lambda, totals, rounds) do
    model = solve(totals, lambda)

    if rounds == 0 do
      model
    else
      detector = EnemyTargets.build_detector(model)
      hard = frames |> Enum.flat_map(&hard_negatives(detector, &1)) |> sums(-1.0, 1.0)
      fit(frames, lambda, sum_all([totals, hard]), rounds - 1)
    end
  end

  defp sums(rows, label, weight) do
    size = EnemyTargets.descriptor_size() + 1
    count = length(rows)

    x =
      rows
      |> Enum.map(&(&1 <> <<1.0::float-32-native>>))
      |> IO.iodata_to_binary()
      |> Evision.Mat.from_binary({:f, 32}, count, size, 1)
      |> Evision.Mat.as_type({:f, 64})

    y = Evision.Mat.from_binary(String.duplicate(<<label::float-64-native>>, count), {:f, 64}, count, 1, 1)

    {
      Evision.gemm(x, x, weight, Evision.Mat.zeros({size, size}, :f64), 0.0, flags: @transpose_first),
      Evision.gemm(x, y, weight, Evision.Mat.zeros({size, 1}, :f64), 0.0, flags: @transpose_first)
    }
  end

  defp sum_all(parts), do: Enum.reduce(parts, fn {a1, b1}, {a2, b2} -> {Evision.add(a1, a2), Evision.add(b1, b2)} end)

  defp solve({a, b}, lambda) do
    ridge = Evision.multiply(Evision.Mat.eye(EnemyTargets.descriptor_size() + 1, :f64), lambda)

    a
    |> Evision.add(ridge)
    |> Evision.solve(b, flags: @cholesky)
    |> Evision.Mat.as_type({:f, 32})
    |> Evision.Mat.to_binary()
  end
end
