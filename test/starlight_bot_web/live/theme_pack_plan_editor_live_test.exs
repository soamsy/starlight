defmodule StarlightBotWeb.Live.ThemePackPlanEditorLiveTest do
  use ExUnit.Case, async: true

  alias StarlightBotWeb.Live.ThemePackPlanEditorLive, as: Live

  describe "toggle_breakpoint/2" do
    test "clicking any floor on an empty schedule sets it as the switch to hard" do
      assert Live.toggle_breakpoint([], 3) == [%{"from_floor" => 3, "mode" => "hard"}]
      assert Live.toggle_breakpoint([], 1) == [%{"from_floor" => 1, "mode" => "hard"}]
    end

    test "clicking the existing switch floor again clears it" do
      schedule = [%{"from_floor" => 3, "mode" => "hard"}]
      assert Live.toggle_breakpoint(schedule, 3) == []
    end

    test "clicking a different floor moves the switch, including from or to floor 1" do
      schedule = [%{"from_floor" => 2, "mode" => "hard"}]
      assert Live.toggle_breakpoint(schedule, 4) == [%{"from_floor" => 4, "mode" => "hard"}]

      schedule = [%{"from_floor" => 1, "mode" => "hard"}]
      assert Live.toggle_breakpoint(schedule, 4) == [%{"from_floor" => 4, "mode" => "hard"}]

      schedule = [%{"from_floor" => 2, "mode" => "hard"}]
      assert Live.toggle_breakpoint(schedule, 1) == [%{"from_floor" => 1, "mode" => "hard"}]
    end
  end

  describe "normalize_mode_schedule/1" do
    test "leaves a valid single-switch schedule alone" do
      assert Live.normalize_mode_schedule([%{"from_floor" => 3, "mode" => "hard"}]) ==
               [%{"from_floor" => 3, "mode" => "hard"}]
    end

    test "leaves an empty (always normal) schedule alone" do
      assert Live.normalize_mode_schedule([]) == []
    end

    test "collapses legacy multi-entry or hard-then-normal schedules to the earliest hard switch" do
      legacy = [
        %{"from_floor" => 1, "mode" => "normal"},
        %{"from_floor" => 2, "mode" => "hard"},
        %{"from_floor" => 4, "mode" => "normal"},
        %{"from_floor" => 6, "mode" => "hard"}
      ]

      assert Live.normalize_mode_schedule(legacy) == [%{"from_floor" => 2, "mode" => "hard"}]
    end

    test "drops a redundant explicit floor-1-normal entry" do
      assert Live.normalize_mode_schedule([%{"from_floor" => 1, "mode" => "normal"}]) == []
    end
  end

  defp pack(id, name, normal_floors, hard_floors) do
    %{id: id, name_en: name, normal_floors: Jason.encode!(normal_floors), hard_floors: Jason.encode!(hard_floors)}
  end

  describe "parse_paste/3" do
    setup do
      %{packs: [pack("thm_1", "The Forgotten", [1, 2], [1, 2]), pack("thm_2", "S.E.A.", [2], [2, 3])]}
    end

    test "accepts a pack with no explicit floors (means all eligible)", %{packs: packs} do
      json = Jason.encode!(%{"mode" => "hard", "packs" => %{"thm_1" => %{}}})
      assert Live.parse_paste(json, packs, "hard") == {:ok, %{"thm_1" => nil}}
    end

    test "accepts a pack scoped to a valid floor subset", %{packs: packs} do
      json = Jason.encode!(%{"mode" => "hard", "packs" => %{"thm_2" => %{"floors" => [2]}}})
      assert Live.parse_paste(json, packs, "hard") == {:ok, %{"thm_2" => [2]}}
    end

    test "bails when the clipboard's mode doesn't match the mode being edited", %{packs: packs} do
      json = Jason.encode!(%{"mode" => "normal", "packs" => %{"thm_1" => %{}}})

      assert Live.parse_paste(json, packs, "hard") ==
               {:error, "Expected hard mode floors, got normal mode floors."}
    end

    test "bails when a pack's floors fall outside what that pack is eligible for", %{packs: packs} do
      json = Jason.encode!(%{"mode" => "hard", "packs" => %{"thm_1" => %{"floors" => [3, 4]}}})

      assert Live.parse_paste(json, packs, "hard") ==
               {:error, "Expected floors 1, 2, got floors 3, 4 for The Forgotten."}
    end

    test "bails on an unknown pack id", %{packs: packs} do
      json = Jason.encode!(%{"mode" => "hard", "packs" => %{"thm_999" => %{}}})
      assert Live.parse_paste(json, packs, "hard") == {:error, "Unknown pack: thm_999."}
    end

    test "bails on a pack that doesn't appear in the target mode at all" do
      json = Jason.encode!(%{"mode" => "normal", "packs" => %{"thm_2" => %{}}})
      packs_normal_only = [pack("thm_2", "S.E.A.", [], [2, 3])]

      assert Live.parse_paste(json, packs_normal_only, "normal") ==
               {:error, "S.E.A. doesn't appear in normal mode."}
    end

    test "bails on malformed JSON", %{packs: packs} do
      assert Live.parse_paste("not json", packs, "hard") == {:error, "Clipboard doesn't contain valid JSON."}
    end

    test "bails when the packs field is missing", %{packs: packs} do
      json = Jason.encode!(%{"mode" => "hard"})
      assert Live.parse_paste(json, packs, "hard") == {:error, "Expected a JSON object with a \"packs\" field."}
    end
  end

  describe "copy_payload/4" do
    test "round-trips through parse_paste" do
      packs = [pack("thm_1", "The Forgotten", [1, 2], [1, 2]), pack("thm_2", "S.E.A.", [2], [2, 3])]

      plan_data = %{
        "packs" => %{
          "thm_1" => %{"hard" => %{"priority" => "hunt"}},
          "thm_2" => %{"hard" => %{"priority" => "hunt", "floors" => [2]}}
        }
      }

      json = Live.copy_payload(plan_data, packs, "hard", "hunt")
      assert {:ok, entries} = Live.parse_paste(json, packs, "hard")
      assert entries == %{"thm_1" => nil, "thm_2" => [2]}
    end
  end
end
