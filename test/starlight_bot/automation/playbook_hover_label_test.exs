defmodule StarlightBot.Automation.PlaybookHoverLabelTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.PlaybookRunner

  test "a label well below the cursor, up to 250px to either side, confirms the hover" do
    assert PlaybookRunner.hover_label_for?({840, 590, 120, 20}, {900, 400})
    assert PlaybookRunner.hover_label_for?({820, 880, 120, 20}, {900, 400})
    assert PlaybookRunner.hover_label_for?({1040, 590, 120, 20}, {900, 400})
    assert PlaybookRunner.hover_label_for?({640, 590, 120, 20}, {900, 400})
  end

  test "a label too close, above, or far to the side doesn't count" do
    refute PlaybookRunner.hover_label_for?({840, 450, 120, 20}, {900, 400})
    refute PlaybookRunner.hover_label_for?({840, 200, 120, 20}, {900, 400})
    refute PlaybookRunner.hover_label_for?({1110, 590, 120, 20}, {900, 400})
    refute PlaybookRunner.hover_label_for?({570, 590, 120, 20}, {900, 400})
  end
end
