defmodule StarlightBot.BattleDebug.Detect do
  alias StarlightBot.Vision.{EnemyTargets, Frame, SinColor, SkillTray}

  def run("chain_tray", %Frame{} = frame) do
    case SkillTray.scan(frame) do
      {:ok, tray} -> {:ok, tray(frame, tray)}
      other -> {:error, {:tray_scan, other}}
    end
  end

  def run("focused_enemies", %Frame{} = frame), do: {:ok, enemies(EnemyTargets.find(frame))}

  def tray(%Frame{mat: mat}, %SkillTray{} = tray) do
    {top, bottom} = SinColor.classify_tray(mat, tray)
    starts = starts(tray.sinner_of_slot)

    slots =
      for i <- 0..(tray.skill_num - 1) do
        %{sinner_start: Enum.at(starts, i), top: cell(Enum.at(top, i)), bottom: cell(Enum.at(bottom, i))}
      end

    %{
      skill_num: tray.skill_num,
      slots: slots,
      geometry: %{
        top: rects(tray.top_row),
        bottom: rects(tray.bottom_row),
        bins: for(i <- 0..(tray.skill_num - 1), do: bin(tray, i))
      }
    }
  end

  def enemies(targets) do
    %{
      enemies:
        Enum.map(targets, fn %EnemyTargets{point: {px, py}, icon: {ix, iy}, zone: zone} ->
          %{x: round(px), y: round(py), icon_x: round(ix), icon_y: round(iy), zone: zone && Tuple.to_list(zone)}
        end)
    }
  end

  defp starts(sinner_of_slot) do
    sinner_of_slot
    |> Enum.with_index()
    |> Enum.map(fn {sinner, i} -> i == 0 or sinner != Enum.at(sinner_of_slot, i - 1) end)
  end

  defp cell(result), do: %{sin: to_string(result.sin), tier: to_string(result.tier), confidence: Float.round(result.confidence * 1.0, 3)}

  defp rects(row) do
    row |> SkillTray.row_columns() |> Enum.map(fn {x0, x1} -> %{x: x0, y: row.y, w: x1 - x0, h: row.h} end)
  end

  defp bin(tray, i), do: %{x0: round(tray.tray_start_x + tray.bin_width * i), x1: round(tray.tray_start_x + tray.bin_width * (i + 1))}
end
