defmodule StarlightBot.DataTest do
  use ExUnit.Case, async: false

  alias StarlightBot.Data

  setup do
    dir = Path.join(System.tmp_dir!(), "starlight_data_test_#{System.unique_integer([:positive])}")
    System.put_env("STARLIGHT_CONFIG", Path.join(dir, "config.toml"))

    on_exit(fn ->
      System.delete_env("STARLIGHT_CONFIG")
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  test "config.toml round-trips mode and data_dir and drops blanks", %{dir: dir} do
    assert Data.settings().config == %{}
    assert :ok = Data.write_config(mode: "user", data_dir: "/somewhere/else")
    assert Data.settings().config == %{"mode" => "user", "data_dir" => "/somewhere/else"}
    assert File.read!(Path.join(dir, "config.toml")) =~ ~s(data_dir = "/somewhere/else")

    assert :ok = Data.write_config(data_dir: "")
    assert Data.settings().config == %{"mode" => "user"}
  end

  test "unknown keys are ignored" do
    assert :ok = Data.write_config(mode: "authoring", evil: "x")
    assert Data.settings().config == %{"mode" => "authoring"}
  end
end
