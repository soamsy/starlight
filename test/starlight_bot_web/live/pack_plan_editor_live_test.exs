defmodule StarlightBotWeb.Live.PackPlanEditorLiveTest do
  use ExUnit.Case, async: true

  alias StarlightBotWeb.Live.PackPlanEditorLive, as: Live

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

  describe "cell_changes/2" do
    test "hunt toggles between none and hunt, from banned too" do
      assert Live.cell_changes(%{1 => "none"}, "hunt") == [{1, "hunt"}]
      assert Live.cell_changes(%{1 => "hunt"}, "hunt") == [{1, "none"}]
      assert Live.cell_changes(%{1 => "favorite"}, "hunt") == [{1, "none"}]
      assert Live.cell_changes(%{1 => "banned"}, "hunt") == [{1, "hunt"}]
    end

    test "hunt on a mixed span hunts the unhunted floors and keeps favorites" do
      assert Live.cell_changes(%{6 => "favorite", 7 => "none", 8 => "banned"}, "hunt") |> Enum.sort() == [{7, "hunt"}, {8, "hunt"}]
      assert Live.cell_changes(%{6 => "favorite", 7 => "hunt"}, "hunt") |> Enum.sort() == [{6, "none"}, {7, "none"}]
    end

    test "banned toggles between none and banned" do
      assert Live.cell_changes(%{1 => "none"}, "banned") == [{1, "banned"}]
      assert Live.cell_changes(%{1 => "hunt"}, "banned") == [{1, "banned"}]
      assert Live.cell_changes(%{1 => "banned"}, "banned") == [{1, "none"}]
    end

    test "favorite toggles only hunted floors" do
      assert Live.cell_changes(%{1 => "none"}, "favorite") == []
      assert Live.cell_changes(%{1 => "banned"}, "favorite") == []
      assert Live.cell_changes(%{1 => "hunt"}, "favorite") == [{1, "favorite"}]
      assert Live.cell_changes(%{1 => "favorite"}, "favorite") == [{1, "hunt"}]
      assert Live.cell_changes(%{1 => "favorite", 2 => "hunt", 3 => "none"}, "favorite") |> Enum.sort() == [{1, "favorite"}, {2, "favorite"}]
    end
  end
end
