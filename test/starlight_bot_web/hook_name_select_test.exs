defmodule StarlightBotWeb.HookNameSelectTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias StarlightBot.{BaseRepo, Hooks}
  alias StarlightBotWeb.Components.HookNameSelect

  @endpoint StarlightBotWeb.Endpoint

  setup do
    :ok = StarlightBot.TestDB.checkout()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    BaseRepo.insert_all("hooks", [
      %{name: "pick_alpha", match_method: "gray", confidence: 0.8, category: "general", mask: false, version: 1, inserted_at: now, updated_at: now}
    ])

    Hooks.invalidate_cache()
    on_exit(&Hooks.invalidate_cache/0)
  end

  test "renders the selected hook in the trigger and a hidden field" do
    html = render_component(&HookNameSelect.hook_name_select/1, id: "hs", name: "hook", selected: "pick_alpha")
    assert html =~ ~s(name="hook" value="pick_alpha")
    assert html =~ "pick_alpha</span>"
  end

  test "shows a placeholder when nothing is selected" do
    assert render_component(&HookNameSelect.hook_name_select/1, id: "hs", name: "hook") =~ "hook name"
  end

  test "names endpoint lists every hook" do
    assert "pick_alpha" in json_response(get(build_conn(), "/hooks/names.json"), 200)
  end
end
