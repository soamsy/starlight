defmodule StarlightBot.Input.DwellTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Input.Dwell

  defp record(ms, anchor, radius) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    started = System.monotonic_time(:millisecond)
    Dwell.run(ms, anchor, radius, fn from, to -> Agent.update(agent, &[{from, to} | &1]) end)
    elapsed = System.monotonic_time(:millisecond) - started
    {Agent.get(agent, &Enum.reverse/1), elapsed}
  end

  test "jitters within the radius" do
    {moves, elapsed} = record(100, {400, 300}, 5)
    assert length(moves) > 2
    assert elapsed >= 95 and elapsed < 160

    for {_from, {x, y}} <- moves do
      assert :math.sqrt((x - 400) ** 2 + (y - 300) ** 2) <= 5.5
    end
  end

  test "each move starts where the previous one ended" do
    {moves, _} = record(100, {400, 300}, 5)
    positions = Enum.flat_map(moves, fn {from, to} -> [from, to] end)
    assert hd(positions) == {400.0, 300.0}

    moves
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [{_, to}, {from, _}] -> assert to == from end)
  end

  test "short dwells just sleep" do
    {moves, elapsed} = record(5, {400, 300}, 5)
    assert moves == []
    assert elapsed >= 4
  end
end
