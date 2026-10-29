defmodule StarlightBot.HooksLayersTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{BaseRepo, Data, Hooks}

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  setup do
    :ok = StarlightBot.TestDB.checkout()
    original = Application.get_env(:starlight_bot, :data_paths)
    Application.put_env(:starlight_bot, :data_paths, %{original | mode: :user})
    Data.reset_cache()

    File.mkdir_p!(Data.base_hooks_dir())
    File.mkdir_p!(Data.user_hooks_dir())
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    BaseRepo.insert_all("hooks", [
      %{name: "layer_shipped", match_method: "gray", confidence: 0.8, notes: "shipped notes", category: "general", mask: false, version: 1, inserted_at: now, updated_at: now}
    ])

    File.write!(Path.join(Data.base_hooks_dir(), "layer_shipped.png"), @png)

    on_exit(fn ->
      Application.put_env(:starlight_bot, :data_paths, original)
      Data.reset_cache()
      File.rm(Path.join(Data.base_hooks_dir(), "layer_shipped.png"))
      File.rm(Path.join(Data.user_hooks_dir(), "layer_shipped.png"))
      File.rm(Path.join(Data.user_hooks_dir(), "layer_mine.png"))
    end)
  end

  test "shipped hooks are read-only until overridden" do
    assert %{source: :base, retired: false} = Hooks.effective_row("layer_shipped")
    refute Hooks.editable?(Hooks.effective_row("layer_shipped"))
    assert {:error, :read_only} = Hooks.update_notes("layer_shipped", "nope")
    assert {:error, :read_only} = Hooks.delete_hook("layer_shipped")
    assert {:error, :read_only} = Hooks.save_hook(%{name: "layer_shipped", image: @png, match_method: "gray", confidence: 0.9})
  end

  test "an override shadows the shipped hook and copies its image" do
    assert {:ok, "layer_shipped"} = Hooks.override_hook("layer_shipped")
    assert File.exists?(Path.join(Data.user_hooks_dir(), "layer_shipped.png"))
    assert {:ok, _} = Hooks.update_notes("layer_shipped", "my notes")

    assert %{source: :override, notes: "my notes", base_version: 1} = Hooks.effective_row("layer_shipped")
    assert Enum.count(Hooks.list_hooks(), &(&1.name == "layer_shipped")) == 1
    assert Hooks.editable?(Hooks.effective_row("layer_shipped"))
    assert {:error, :already_overridden} = Hooks.override_hook("layer_shipped")
  end

  test "bumping the shipped version retires the override until it is re-applied" do
    {:ok, _} = Hooks.override_hook("layer_shipped")
    {:ok, _} = Hooks.update_notes("layer_shipped", "my notes")

    BaseRepo.query!("UPDATE hooks SET version = 2 WHERE name = 'layer_shipped'")
    assert %{source: :base, retired: true, notes: "shipped notes"} = Hooks.effective_row("layer_shipped")

    assert {:ok, _} = Hooks.reapply_hook("layer_shipped")
    assert %{source: :override, retired: false, notes: "my notes", version: 2} = Hooks.effective_row("layer_shipped")
  end

  test "deleting an override falls back to the shipped hook" do
    {:ok, _} = Hooks.override_hook("layer_shipped")
    assert {:ok, _} = Hooks.delete_hook("layer_shipped")
    assert %{source: :base, retired: false} = Hooks.effective_row("layer_shipped")
    refute File.exists?(Path.join(Data.user_hooks_dir(), "layer_shipped.png"))
  end

  test "user-created hooks are editable and cannot reuse a shipped name" do
    assert {:ok, "layer_mine"} = Hooks.save_hook(%{name: "layer_mine", image: @png, match_method: "gray", confidence: 0.8})
    assert %{source: :user} = Hooks.effective_row("layer_mine")
    assert {:ok, _} = Hooks.update_notes("layer_mine", "hello")
    assert {:error, :name_taken} = Hooks.duplicate_hook("layer_mine", "layer_shipped")
    assert {:ok, _} = Hooks.delete_hook("layer_mine")
    assert Hooks.effective_row("layer_mine") == nil
  end

  test "bumping versions only works while authoring" do
    assert {:error, :not_authoring} = Hooks.bump_version("layer_shipped")
  end
end
