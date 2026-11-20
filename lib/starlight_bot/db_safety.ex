defmodule StarlightBot.DbSafety do
  require Logger

  alias StarlightBot.Data

  @keep_recent 3
  @keep_days 7
  @boot_backup_interval 3600
  @term_key {__MODULE__, :problems}

  def watched_paths do
    paths = Data.paths()
    [paths.base, paths.user, paths.runs]
  end

  def backup_dir, do: Path.join(Data.paths().root, "backups")

  def holders do
    files = for path <- watched_paths(), suffix <- ["", "-wal", "-shm"], File.exists?(path <> suffix), do: path <> suffix

    with [_ | _] <- files,
         lsof when is_binary(lsof) <- System.find_executable("lsof"),
         {out, _status} <- System.cmd(lsof, ["-t" | files], stderr_to_stdout: true) do
      out
      |> String.split()
      |> Enum.uniq()
      |> Enum.reject(&(&1 == System.pid()))
      |> Enum.map(&{&1, command(&1)})
    else
      _ -> []
    end
  end

  defp command(pid) do
    {out, _status} = System.cmd("ps", ["-o", "args=", "-p", pid], stderr_to_stdout: true)
    String.trim(out)
  end

  def quick_check(path) do
    case query(path, "PRAGMA quick_check") do
      {:ok, [["ok"]]} -> :ok
      {:ok, rows} -> {:error, rows |> List.flatten() |> Enum.take(5) |> Enum.map(&to_string/1)}
      {:error, reason} -> {:error, [to_string(reason)]}
    end
  end

  defp query(path, sql) do
    with {:ok, conn} <- Exqlite.Sqlite3.open(path, mode: :readonly) do
      try do
        with {:ok, statement} <- Exqlite.Sqlite3.prepare(conn, sql),
             {:ok, rows} <- Exqlite.Sqlite3.fetch_all(conn, statement) do
          Exqlite.Sqlite3.release(conn, statement)
          {:ok, rows}
        end
      after
        Exqlite.Sqlite3.close(conn)
      end
    end
  end

  def backup(min_age \\ 0) do
    paths = Data.paths()
    base = if Data.base_writable?(), do: [paths.base], else: []

    for path <- base ++ [paths.user], File.exists?(path) do
      {Path.basename(path, ".db"), backup_one(path, min_age)}
    end
  end

  defp backup_one(path, min_age) do
    name = Path.basename(path, ".db")
    dir = backup_dir()
    dest = Path.join(dir, "#{name}-#{Calendar.strftime(NaiveDateTime.local_now(), "%Y%m%dT%H%M%S")}.db")

    cond do
      File.exists?(dest) -> :recent
      newest_age(dir, name) < min_age -> :recent
      true ->
        with :ok <- quick_check(path),
             :ok <- File.mkdir_p(dir),
             :ok <- vacuum_into(path, dest) do
          prune(dir, name)
          {:ok, dest}
        end
    end
  end

  defp backups(dir, name), do: dir |> Path.join("#{name}-*.db") |> Path.wildcard() |> Enum.sort(:desc)

  defp newest_age(dir, name) do
    case backups(dir, name) do
      [newest | _] -> System.os_time(:second) - File.stat!(newest, time: :posix).mtime
      [] -> :infinity
    end
  end

  defp prune(dir, name) do
    all = backups(dir, name)
    recent = Enum.take(all, @keep_recent)
    daily = all |> Enum.uniq_by(&backup_day/1) |> Enum.take(@keep_days)

    (all -- recent ++ daily) |> Enum.each(&File.rm/1)
  end

  defp backup_day(file), do: file |> Path.basename() |> String.slice(-18, 8)

  defp vacuum_into(path, dest) do
    with {:ok, conn} <- Exqlite.Sqlite3.open(path, mode: :readonly) do
      try do
        case Exqlite.Sqlite3.execute(conn, "VACUUM INTO '#{String.replace(dest, "'", "''")}'") do
          :ok -> :ok
          {:error, reason} -> {:error, [to_string(reason)]}
        end
      after
        Exqlite.Sqlite3.close(conn)
      end
    end
  end

  def boot_check do
    apply_pending()

    problems =
      for {name, path} <- repair_targets(), File.exists?(path), {:error, messages} <- [quick_check(path)] do
        Logger.error("Database #{name} failed its integrity check: #{Enum.join(messages, "; ")}. Backups are in #{backup_dir()}")
        %{name: name, messages: messages}
      end

    :persistent_term.put(@term_key, problems)

    for {name, {:error, messages}} <- backup(@boot_backup_interval), name not in Enum.map(problems, & &1.name) do
      Logger.error("Database #{name} could not be backed up: #{Enum.join(messages, "; ")}")
    end

    :ok
  end

  def repair_targets do
    paths = Data.paths()
    base = if Data.base_writable?(), do: [paths.base], else: []
    for path <- base ++ [paths.user, paths.runs], do: {Path.basename(path, ".db"), path}
  end

  def problems do
    for problem <- :persistent_term.get(@term_key, []) do
      latest = latest_backup(problem.name)

      Map.merge(problem, %{
        label: label(problem.name),
        backup: latest,
        backup_at: latest && backup_time(latest),
        can_fresh?: problem.name == "runs" or Data.user_mode?(),
        pending: File.exists?(marker_path(problem.name))
      })
    end
  end

  defp label("runs"), do: "Run history"
  defp label("base"), do: "Shipped data"
  defp label(_name), do: "Plans and settings"

  defp latest_backup(name), do: backup_dir() |> backups(name) |> List.first()

  defp backup_time(file), do: file |> File.stat!(time: :local) |> Map.fetch!(:mtime) |> NaiveDateTime.from_erl!()

  def request_repair(name, :restore) do
    case latest_backup(name) do
      nil -> {:error, :no_backup}
      backup -> write_marker(name, backup)
    end
  end

  def request_repair(name, :fresh), do: write_marker(name, "fresh")

  defp write_marker(name, content) do
    with :ok <- File.mkdir_p(Data.paths().root), do: File.write(marker_path(name), content)
  end

  defp marker_path(name), do: Path.join(Data.paths().root, "repair-#{name}")

  defp apply_pending do
    for {name, path} <- repair_targets(), {:ok, action} <- [File.read(marker_path(name))] do
      File.rm(marker_path(name))
      repair(name, path, String.trim(action))
    end

    :ok
  end

  defp repair(name, path, "fresh"), do: move_aside(name, path)

  defp repair(name, path, source) do
    with true <- Path.dirname(source) == backup_dir(),
         :ok <- quick_check(source),
         :ok <- move_aside(name, path),
         :ok <- File.cp(source, path),
         :ok <- enable_wal(path) do
      Logger.warning("Restored database #{name} from #{source}")
    else
      _ -> Logger.error("Could not restore database #{name} from #{source}")
    end
  end

  defp move_aside(name, path) do
    dir = Path.join(Data.paths().root, "damaged")
    stamp = Calendar.strftime(NaiveDateTime.local_now(), "%Y%m%dT%H%M%S")

    with :ok <- File.mkdir_p(dir) do
      for suffix <- ["", "-wal", "-shm"], File.exists?(path <> suffix) do
        File.rename!(path <> suffix, Path.join(dir, "#{name}-#{stamp}.db#{suffix}"))
      end

      :ok
    end
  end

  defp enable_wal(path) do
    with {:ok, conn} <- Exqlite.Sqlite3.open(path) do
      try do
        Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
      after
        Exqlite.Sqlite3.close(conn)
      end
    end
  end
end
