defmodule StarlightBot.Automation.Shop.Actions.IngredientRefuseTest do
  use ExUnit.Case, async: false

  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Actions.Section
  alias StarlightBot.{Ctx, GiftPlans}

  defmodule NoFrameCapture do
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: StarlightBot.Vision.Capture)
    def init(_), do: {:ok, nil}
    def handle_call(_msg, _from, state), do: {:reply, {:error, :no_frame}, state}
  end

  defmodule NoKeyboard do
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: StarlightBot.Input.Keyboard)
    def init(_), do: {:ok, nil}
    def handle_call(_msg, _from, state), do: {:reply, :ok, state}
  end

  defp entry(id, gift, segment, fusion) do
    %{"id" => id, "subject" => %{"gift" => gift}, "fusion" => fusion, "floors" => [Map.merge(GiftPlans.default_segment(), segment)]}
  end

  setup do
    :ok = StarlightBot.TestDB.checkout()
    start_supervised!(NoFrameCapture)
    start_supervised!(NoKeyboard)
    {:ok, pid} = RunMemory.start_link()
    ctx = Ctx.new(run_memory: pid)
    RunMemory.put_cost(ctx, 300)

    section = %{
      "id" => "ms_main",
      "name" => "Main",
      "pursue_optional" => true,
      "goals" => [],
      "entries" => [
        entry("me_fixed", "Fixed", %{"goal" => "required", "fuse" => true, "buy" => false}, %{"type" => "fixed"}),
        entry("me_x", "X", %{"goal" => "optional", "fuse" => true, "buy" => false}, %{"type" => "tiered", "routes" => []})
      ]
    }

    gifts = [%{id: "g_fixed", name: "Fixed", tier: 4, ingredients: "g_x", selling_cost: 0}, %{id: "g_x", name: "X", tier: 2, selling_cost: 0}]

    state = %{
      plan: %{"sections" => [section]},
      floor: 1,
      reserve: 0,
      shop_type: :normal,
      protected: MapSet.new(),
      refreshes: 0,
      sell_popup_open: false,
      gifts_by_name: Map.new(gifts, &{&1.name, &1}),
      gifts_by_id: Map.new(gifts, &{&1.id, &1})
    }

    %{ctx: ctx, state: state, section: section}
  end

  test "an optional tiered ingredient already consumed by an owned fixed fusion is not fused for again", %{ctx: ctx, state: state, section: section} do
    RunMemory.add_ego_gift(ctx, "g_fixed", "Fixed")

    {_outcome, detail, _state} = Section.run(%{}, section, state, ctx)

    refute detail =~ "X:"
  end
end
