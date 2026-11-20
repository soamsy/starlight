defmodule StarlightBot.DbSafetyTest do
  use ExUnit.Case, async: false

  alias StarlightBot.DbSafety

  setup do
    dir = DbSafety.backup_dir()
    clear = fn -> dir |> Path.join("*.db") |> Path.wildcard() |> Enum.each(&File.rm/1) end
    clear.()
    on_exit(clear)
    %{dir: dir}
  end

  test "quick_check passes on a healthy database and fails on garbage" do
    assert :ok = DbSafety.quick_check(StarlightBot.Data.paths().user)

    garbage = Path.join(System.tmp_dir!(), "starlight_garbage_#{System.unique_integer([:positive])}.db")
    File.write!(garbage, String.duplicate("not a database", 500))
    on_exit(fn -> File.rm(garbage) end)

    assert {:error, [_ | _]} = DbSafety.quick_check(garbage)
  end

  test "backup writes a restorable copy of each writable database", %{dir: dir} do
    results = DbSafety.backup()

    assert [{"starlight_test_base", {:ok, base}}, {"starlight_test_user", {:ok, user}}] = results
    assert Path.dirname(base) == dir
    assert :ok = DbSafety.quick_check(base)
    assert :ok = DbSafety.quick_check(user)
  end

  test "backup skips a database that was backed up recently" do
    assert [{_, {:ok, _}}, {_, {:ok, _}}] = DbSafety.backup(3600)
    assert [{_, :recent}, {_, :recent}] = DbSafety.backup(3600)
  end

  test "backup keeps the newest three plus one per day for seven days", %{dir: dir} do
    File.mkdir_p!(dir)

    for day <- 1..10, stamp <- ~w(000001 000002) do
      File.write!(Path.join(dir, "starlight_test_user-202001#{String.pad_leading("#{day}", 2, "0")}T#{stamp}.db"), "")
    end

    assert [_, {"starlight_test_user", {:ok, fresh}}] = DbSafety.backup()

    kept = dir |> Path.join("starlight_test_user-*.db") |> Path.wildcard() |> Enum.map(&Path.basename/1) |> Enum.sort()

    assert kept ==
             Enum.sort([
               Path.basename(fresh),
               "starlight_test_user-20200110T000001.db",
               "starlight_test_user-20200110T000002.db",
               "starlight_test_user-20200109T000002.db",
               "starlight_test_user-20200108T000002.db",
               "starlight_test_user-20200107T000002.db",
               "starlight_test_user-20200106T000002.db",
               "starlight_test_user-20200105T000002.db"
             ])
  end

  test "holders reports another process that has a database open" do
    sh = System.find_executable("sh")
    user = StarlightBot.Data.paths().user
    port = Port.open({:spawn_executable, sh}, args: ["-c", "exec 3< #{user}; sleep 5"])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Process.sleep(300)

    assert Enum.any?(DbSafety.holders(), fn {pid, _command} -> pid == Integer.to_string(os_pid) end)

    System.cmd("kill", [Integer.to_string(os_pid)])
  end

  describe "repair" do
    @describetag :capture_log

    setup do
      root = Path.join(System.tmp_dir!(), "starlight_repair_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      previous = Application.get_env(:starlight_bot, :data_paths)

      Application.put_env(:starlight_bot, :data_paths, %{
        mode: :user,
        root: root,
        base: Path.join(root, "base.db"),
        user: Path.join(root, "user.db"),
        runs: Path.join(root, "runs.db")
      })

      StarlightBot.Data.reset_cache()
      {:ok, conn} = Exqlite.Sqlite3.open(Path.join(root, "user.db"))
      :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE notes (body TEXT); INSERT INTO notes VALUES ('kept')")
      Exqlite.Sqlite3.close(conn)

      on_exit(fn ->
        Application.put_env(:starlight_bot, :data_paths, previous)
        StarlightBot.Data.reset_cache()
        :persistent_term.erase({DbSafety, :problems})
        root |> Path.join("**") |> Path.wildcard() |> Enum.filter(&File.regular?/1) |> Enum.each(&File.rm/1)
      end)

      %{root: root, user: Path.join(root, "user.db")}
    end

    defp damage(path), do: File.write!(path, String.duplicate("not a database", 500))

    defp notes(path) do
      {:ok, conn} = Exqlite.Sqlite3.open(path, mode: :readonly)
      {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "SELECT body FROM notes")
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, statement)
      Exqlite.Sqlite3.close(conn)
      rows
    end

    test "a healthy database reports no problems" do
      DbSafety.boot_check()
      assert DbSafety.problems() == []
    end

    test "a damaged database is reported with its newest backup", %{user: user} do
      DbSafety.boot_check()
      damage(user)
      DbSafety.boot_check()

      assert [%{name: "user", backup: backup, pending: false, can_fresh?: true, messages: [_ | _]}] = DbSafety.problems()
      assert is_binary(backup)
    end

    test "restore swaps in the backup on the next boot and keeps the damaged file", %{root: root, user: user} do
      DbSafety.boot_check()
      damage(user)
      DbSafety.boot_check()

      assert :ok = DbSafety.request_repair("user", :restore)
      assert [%{pending: true}] = DbSafety.problems()

      DbSafety.boot_check()

      assert DbSafety.problems() == []
      assert [["kept"]] = notes(user)
      assert [_] = Path.wildcard(Path.join([root, "damaged", "user-*.db"]))
      assert {:ok, conn} = Exqlite.Sqlite3.open(user, mode: :readonly)
      {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "PRAGMA journal_mode")
      assert {:ok, [["wal"]]} = Exqlite.Sqlite3.fetch_all(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end

    test "start fresh moves the file aside", %{root: root, user: user} do
      DbSafety.boot_check()
      damage(user)
      DbSafety.boot_check()

      assert :ok = DbSafety.request_repair("user", :fresh)
      DbSafety.boot_check()

      refute File.exists?(user)
      assert DbSafety.problems() == []
      assert [_] = Path.wildcard(Path.join([root, "damaged", "user-*.db"]))
    end

    test "restore with no backup is refused" do
      assert {:error, :no_backup} = DbSafety.request_repair("user", :restore)
    end
  end
end
