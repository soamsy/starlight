defmodule StarlightBot.Vision.TierModelTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Vision.TierModel
  alias StarlightBot.Vision.TierModel.Trainer

  defp mask(fill), do: Evision.Mat.full({35, 36}, fill, :u8)

  describe "features/4" do
    test "has the model's feature size and one-hot encodes the sin" do
      features = TierModel.features(:gloom, 0.4, 0.2, mask(0))
      assert length(features) == TierModel.feature_size()
      assert Enum.slice(features, 0, 2) == [0.4, 0.2]
      assert Enum.slice(features, 2, 7) == [0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0]
    end

    test "grid cells carry the matched share of the mask" do
      empty = TierModel.features(:wrath, 0.0, 0.0, mask(0))
      full = TierModel.features(:wrath, 0.0, 0.0, mask(255))
      assert Enum.drop(empty, 9) |> Enum.all?(&(&1 == 0.0))
      assert Enum.drop(full, 9) |> Enum.all?(&(&1 == 1.0))
    end
  end

  describe "predict/2" do
    test "picks the class with the highest linear score after standardization" do
      size = TierModel.feature_size()
      mean = List.duplicate(0.0, size)
      std = List.duplicate(1.0, size)
      weights = for row <- 0..size, class <- 0..2, do: if(row == 0 and class == 2, do: 1.0, else: 0.0)
      model = mean |> TierModel.encode(std, weights) |> TierModel.decode()

      high = [1.0 | List.duplicate(0.0, size - 1)]
      low = [-1.0 | List.duplicate(0.0, size - 1)]
      assert TierModel.predict(model, high) == :skill3
      assert TierModel.predict(model, low) == :skill1
    end
  end

  describe "Trainer.fit/2" do
    test "learns a separable problem and survives constant features" do
      size = TierModel.feature_size()

      rows =
        for i <- 1..60 do
          label = rem(i, 3)
          features = List.duplicate(0.0, size) |> List.replace_at(label, 1.0) |> List.replace_at(3, rem(i, 5) * 0.1)
          %{features: features, label: label}
        end

      model = rows |> Trainer.fit(1.0) |> TierModel.decode()
      predicted = Enum.map(rows, &TierModel.predict(model, &1.features))
      expected = Enum.map(rows, &Enum.at(TierModel.tiers(), &1.label))
      assert predicted == expected
    end
  end
end
