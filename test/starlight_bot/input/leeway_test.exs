defmodule StarlightBot.Input.LeewayTest do
  use ExUnit.Case, async: true
  alias StarlightBot.Input.Leeway

  test "in_rect samples the middle half of a big rect" do
    for _ <- 1..200 do
      {x, y} = Leeway.in_rect({100, 200, 80, 40})
      assert x >= 120 and x <= 160
      assert y >= 210 and y <= 230
    end
  end

  test "in_rect falls back to a 5px radius around the center when the half box is too small" do
    for _ <- 1..200 do
      {x, y} = Leeway.in_rect({100, 200, 30, 12})
      assert :math.sqrt((x - 115) * (x - 115) + (y - 206) * (y - 206)) <= 5.7
    end
  end

  test "click stays within 5px" do
    for _ <- 1..200 do
      {x, y} = Leeway.click({500, 500})
      assert :math.sqrt((x - 500) * (x - 500) + (y - 500) * (y - 500)) <= 5.7
    end
  end
end
