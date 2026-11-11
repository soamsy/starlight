defmodule StarlightBot.Vision.TierModel.Trainer do
  alias StarlightBot.BattleDebug
  alias StarlightBot.Vision.{SinColor, SkillTray, TierModel}

  @lambda 500.0
  @max_folds 8
  @min_std 1.0e-6
  @transpose_first 1
  @cholesky 3

  def lambda, do: @lambda

  def suite_rows do
    BattleDebug.list()
    |> Enum.filter(&(&1["kind"] == "chain_tray" and &1["in_suite?"]))
    |> Enum.flat_map(fn %{"id" => id} = record ->
      with {:ok, frame} <- BattleDebug.load_frame(id),
           {:ok, tray} <- SkillTray.scan(frame) do
        rows(id, frame, tray, BattleDebug.truth(id, record)["slots"])
      else
        _ -> []
      end
    end)
  end

  def fit(rows, lambda \\ @lambda) do
    size = TierModel.feature_size()
    features = Enum.map(rows, & &1.features)
    count = length(features)
    {mean, std} = standardization(features)

    x =
      features
      |> Enum.map(&standardize(&1, mean, std))
      |> Enum.map(&(&1 ++ [1.0]))
      |> to_mat(count, size + 1)

    y = rows |> Enum.map(&one_hot(&1.label)) |> to_mat(count, length(TierModel.tiers()))
    gram = Evision.gemm(x, x, 1.0, Evision.Mat.zeros({size + 1, size + 1}, :f64), 0.0, flags: @transpose_first)
    target = Evision.gemm(x, y, 1.0, Evision.Mat.zeros({size + 1, length(TierModel.tiers())}, :f64), 0.0, flags: @transpose_first)
    ridge = Evision.multiply(Evision.Mat.eye(size + 1, :f64), lambda)

    weights =
      gram
      |> Evision.add(ridge)
      |> Evision.solve(target, flags: @cholesky)
      |> Evision.Mat.to_nx()
      |> Nx.to_flat_list()

    TierModel.encode(mean, std, weights)
  end

  def cross_validate(rows, lambda \\ @lambda) do
    groups = rows |> Enum.map(&group/1) |> Enum.uniq() |> Enum.sort()
    folds = min(length(groups), @max_folds)
    fold_of = groups |> Enum.with_index() |> Map.new(fn {group, index} -> {group, rem(index, folds)} end)

    0..(folds - 1)
    |> Task.async_stream(
      fn fold ->
        {held, train} = Enum.split_with(rows, &(Map.fetch!(fold_of, group(&1)) == fold))
        model = train |> fit(lambda) |> TierModel.decode()
        Enum.map(held, &Map.put(&1, :predicted, TierModel.predict(model, &1.features)))
      end,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.flat_map(fn {:ok, predictions} -> predictions end)
  end

  def write_model(model) do
    path = Path.expand("priv/vision/tier_model.f32")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, model)
    TierModel.reload()
    path
  end

  def errors(rows, key), do: Enum.count(rows, &(Map.fetch!(&1, key) != &1.truth))

  defp rows(id, frame, tray, truth) do
    bg = SinColor.background_color(frame.mat, SkillTray.background_region(tray))

    for {key, row} <- [{"top", tray.top_row}, {"bottom", tray.bottom_row}],
        classified = SinColor.classify_row(frame.mat, row, bg.hue, bg.saturation, bg.value, bg.leak, bg.unmix_bgr),
        {result, slot} <- Enum.with_index(classified) do
      %{
        id: id,
        row: key,
        slot: slot,
        features: result.tier_features,
        label: label(Enum.at(truth, slot)[key]["tier"]),
        truth: String.to_existing_atom(Enum.at(truth, slot)[key]["tier"]),
        rule: result.rule_tier
      }
    end
  end

  defp group(row), do: String.slice(row.id, 0, 13)

  defp label(tier), do: Enum.find_index(TierModel.tiers(), &(Atom.to_string(&1) == tier))

  defp one_hot(label), do: for(index <- 0..(length(TierModel.tiers()) - 1), do: if(index == label, do: 1.0, else: 0.0))

  defp standardization(features) do
    matrix = Nx.tensor(features, type: :f64)
    mean = Nx.mean(matrix, axes: [0])
    std = matrix |> Nx.subtract(mean) |> Nx.pow(2) |> Nx.mean(axes: [0]) |> Nx.sqrt()
    {Nx.to_flat_list(mean), std |> Nx.to_flat_list() |> Enum.map(&if(&1 < @min_std, do: 1.0, else: &1))}
  end

  defp standardize(features, mean, std) do
    [features, mean, std] |> Enum.zip_with(fn [value, m, s] -> (value - m) / s end)
  end

  defp to_mat(rows, count, columns) do
    rows
    |> List.flatten()
    |> Enum.map(&<<&1::float-64-native>>)
    |> IO.iodata_to_binary()
    |> Evision.Mat.from_binary({:f, 64}, count, columns, 1)
  end
end
