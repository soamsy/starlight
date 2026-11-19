defmodule StarlightBotWeb.HookEditorRowsTest do
  use ExUnit.Case, async: true

  alias StarlightBotWeb.Live.HookEditorLive

  @hooks for i <- 1..250, do: %{name: "hook_#{String.pad_leading(to_string(i), 3, "0")}", inserted_at: i}

  test "visible hooks sorts and filters before applying the limit" do
    rows = HookEditorLive.visible_hooks(@hooks, "", :name, :desc, 100)
    assert length(rows) == 100
    assert hd(rows).name == "hook_250"

    assert [%{name: "hook_007"}] = HookEditorLive.visible_hooks(@hooks, "hook_007", :name, :asc, 100)
  end

  test "total counts every match regardless of the limit" do
    assert HookEditorLive.hooks_total(@hooks, "") == 250
    assert HookEditorLive.hooks_total(@hooks, "hook_1") == 100
  end
end
