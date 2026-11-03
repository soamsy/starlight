defmodule StarlightBot.BattleDebug.VerifyTest do
  use ExUnit.Case, async: true
  alias StarlightBot.BattleDebug
  alias StarlightBot.BattleDebug.Verify

  defp slot(sin, tier, start?) do
    %{"sinner_start" => start?, "top" => %{"sin" => sin, "tier" => tier}, "bottom" => %{"sin" => "pride", "tier" => "skill1"}}
  end

  test "tray detection matching the labels passes" do
    slots = [slot("wrath", "skill3", true), slot("lust", "skill2", false)]
    assert %{ok?: true, diffs: []} = Verify.compare("chain_tray", %{"slots" => slots}, %{"slots" => slots})
  end

  test "tray diffs name the slot, field and both values" do
    truth = %{"slots" => [slot("wrath", "skill3", true), slot("lust", "skill2", false)]}
    detected = %{"slots" => [slot("wrath", "skill2", true), slot("lust", "skill2", true)]}

    assert %{ok?: false, diffs: diffs, summary: summary} = Verify.compare("chain_tray", truth, detected)
    assert %{slot: 0, field: "top_tier", expected: "skill3", actual: "skill2"} in diffs
    assert %{slot: 1, field: "sinner_start", expected: false, actual: true} in diffs
    assert summary =~ "1 tier"
  end

  test "slot count mismatch fails" do
    truth = %{"slots" => [slot("wrath", "skill3", true)]}
    detected = %{"slots" => [slot("wrath", "skill3", true), slot("lust", "skill1", false)]}
    assert %{ok?: false, diffs: [%{field: "slot_count"} | _]} = Verify.compare("chain_tray", truth, detected)
  end

  describe "enemies" do
    @truth %{"rects" => [%{"x" => 100, "y" => 100, "w" => 100, "h" => 100}, %{"x" => 400, "y" => 100, "w" => 100, "h" => 100}]}

    test "points inside the boxes pass" do
      detected = %{"enemies" => [%{"x" => 150, "y" => 150}, %{"x" => 450, "y" => 120}]}
      assert %{ok?: true, matched: [_, _], missed: [], extra: []} = Verify.compare("focused_enemies", @truth, detected)
    end

    test "a box without a detection is a miss and a stray detection is extra" do
      detected = %{"enemies" => [%{"x" => 150, "y" => 150}, %{"x" => 900, "y" => 900}]}
      assert %{ok?: false, missed: [%{"x" => 400}], extra: [%{"x" => 900}], summary: "1 missed, 1 extra"} = Verify.compare("focused_enemies", @truth, detected)
    end

    test "two detections in one box count the second as extra" do
      detected = %{"enemies" => [%{"x" => 150, "y" => 150}, %{"x" => 160, "y" => 160}, %{"x" => 450, "y" => 150}]}
      assert %{ok?: false, missed: [], extra: [%{"x" => 160}]} = Verify.compare("focused_enemies", @truth, detected)
    end

    test "default labels box each recorded detection" do
      record = %{"kind" => "focused_enemies", "detected" => %{"enemies" => [%{"x" => 300, "y" => 400}, %{"x" => 800, "y" => 420}]}}
      detected = record["detected"]
      assert %{ok?: true} = Verify.compare("focused_enemies", BattleDebug.default_truth(record), detected)
    end
  end

  test "default tray labels match the recorded detection" do
    slots = [Map.put(slot("wrath", "skill3", true), "top", %{"sin" => "wrath", "tier" => "skill3", "confidence" => 1.0}) |> Map.put("bottom", %{"sin" => "pride", "tier" => "skill1", "confidence" => 0.9})]
    record = %{"kind" => "chain_tray", "detected" => %{"slots" => slots}}
    assert %{ok?: true} = Verify.compare("chain_tray", BattleDebug.default_truth(record), %{"slots" => slots})
  end
end
