defmodule StarlightBot.Vision.EnemyTargetsTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Vision.{EnemyTargets, Frame}

  test "suppress keeps the strongest candidate in each neighbourhood" do
    candidates = [{100, 100, 0.5}, {110, 105, 0.9}, {400, 300, 0.4}, {420, 310, 0.2}]
    assert [{110, 105, 0.9}, {400, 300, 0.4}] = EnemyTargets.suppress(candidates)
  end

  test "suppress leaves well separated candidates alone" do
    candidates = [{100, 100, 0.5}, {300, 100, 0.6}]
    assert [{300, 100, 0.6}, {100, 100, 0.5}] = EnemyTargets.suppress(candidates)
  end

  test "the shipped model matches the descriptor size" do
    assert File.stat!(EnemyTargets.model_path()).size == (EnemyTargets.descriptor_size() + 1) * 4
  end

  test "a blank battle frame has no targets" do
    {w, h} = Frame.normalized_size()
    mat = Evision.Mat.from_binary(:binary.copy(<<0>>, w * h * 3), {:u, 8}, h, w, 3)
    frame = %Frame{mat: mat, window_rect: {0, 0, w, h}, scale: 1.0, captured_at: 0}
    assert EnemyTargets.find(frame) == []
  end
end
