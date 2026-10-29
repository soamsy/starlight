defmodule StarlightBot.SinnerProfilesTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{BaseRepo, Data, SinnerProfiles}

  setup do
    :ok = StarlightBot.TestDB.checkout()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    BaseRepo.insert_all("sinner_profiles", [%{id: 7, name: "Shipped Faust", sinner: "faust", inserted_at: now, updated_at: now}])

    original = Application.get_env(:starlight_bot, :data_paths)
    Application.put_env(:starlight_bot, :data_paths, %{original | mode: :user})
    Data.reset_cache()

    on_exit(fn ->
      Application.put_env(:starlight_bot, :data_paths, original)
      Data.reset_cache()
    end)
  end

  test "user profiles get ids above the shipped range and list beside shipped ones" do
    assert {:ok, id} = SinnerProfiles.save(%{name: "Mine", sinner: "faust"})
    assert id >= SinnerProfiles.user_id_floor()
    assert {:ok, next} = SinnerProfiles.save(%{name: "Mine Two", sinner: "faust"})
    assert next == id + 1

    assert [{7, :base}, {^id, :user}, {^next, :user}] =
             SinnerProfiles.list() |> Enum.map(&{&1.id, &1.source}) |> Enum.sort_by(&elem(&1, 0))
  end

  test "shipped profiles are read-only and names stay unique across both layers" do
    assert {:error, :read_only} = SinnerProfiles.save(%{id: 7, name: "Renamed", sinner: "faust"})
    assert {:error, :read_only} = SinnerProfiles.delete(7)
    assert {:error, :name_taken} = SinnerProfiles.save(%{name: "Shipped Faust", sinner: "faust"})

    {:ok, id} = SinnerProfiles.save(%{name: "Mine", sinner: "faust"})
    assert {:ok, ^id} = SinnerProfiles.save(%{id: id, name: "Mine Renamed", sinner: "faust"})
    assert {:ok, ^id} = SinnerProfiles.delete(id)
  end
end
