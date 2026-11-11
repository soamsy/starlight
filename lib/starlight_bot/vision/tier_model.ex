defmodule StarlightBot.Vision.TierModel do
  @model_file "priv/vision/tier_model.f32"
  @grid 24
  @sins [:wrath, :lust, :sloth, :gluttony, :gloom, :pride, :envy]
  @tiers [:skill1, :skill2, :skill3]
  @feature_size 2 + 7 + @grid * @grid
  @class_count 3

  def grid, do: @grid
  def sins, do: @sins
  def tiers, do: @tiers
  def feature_size, do: @feature_size
  def model_path, do: Application.app_dir(:starlight_bot, @model_file)

  def features(sin, tier_pct, flame, raw_mask) do
    [tier_pct, flame] ++ Enum.map(@sins, &if(&1 == sin, do: 1.0, else: 0.0)) ++ cell_grid(raw_mask)
  end

  def predict(features) do
    case model() do
      nil -> nil
      model -> predict(model, features)
    end
  end

  def predict(model, features) do
    x = features |> Nx.tensor(type: :f32) |> Nx.subtract(model.mean) |> Nx.divide(model.std)
    logits = [x, Nx.tensor([1.0], type: :f32)] |> Nx.concatenate() |> Nx.dot(model.weights)
    Enum.at(@tiers, logits |> Nx.argmax() |> Nx.to_number())
  end

  def encode(mean, std, weights) do
    [mean, std, weights] |> Enum.map(&floats_to_binary/1) |> IO.iodata_to_binary()
  end

  def decode(binary) do
    stats_bytes = @feature_size * 4
    <<mean::binary-size(^stats_bytes), std::binary-size(^stats_bytes), weights::binary>> = binary

    %{
      mean: Nx.from_binary(mean, :f32),
      std: Nx.from_binary(std, :f32),
      weights: weights |> Nx.from_binary(:f32) |> Nx.reshape({@feature_size + 1, @class_count})
    }
  end

  def model do
    case :persistent_term.get({__MODULE__, :model}, nil) do
      nil -> load()
      model -> model
    end
  end

  def reload, do: :persistent_term.erase({__MODULE__, :model})

  defp load do
    case File.read(model_path()) do
      {:ok, binary} ->
        model = decode(binary)
        :persistent_term.put({__MODULE__, :model}, model)
        model

      {:error, _} ->
        nil
    end
  end

  defp cell_grid(mask) do
    mask
    |> Evision.resize({@grid, @grid}, interpolation: Evision.Constant.cv_INTER_AREA())
    |> Evision.Mat.to_nx()
    |> Nx.divide(255)
    |> Nx.to_flat_list()
  end

  defp floats_to_binary(values), do: Enum.map(values, &<<&1::float-32-native>>)
end
