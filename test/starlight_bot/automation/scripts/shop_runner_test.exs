defmodule StarlightBot.Automation.Scripts.ShopRunnerTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Scripts.ShopRunner
  alias StarlightBot.{Ctx, GiftPlans}

  defp section(id, gift, extra \\ %{}) do
    segment = GiftPlans.default_segment()
    entry = %{"id" => "me_" <> id, "subject" => %{"gift" => gift}, "fusion" => nil, "floors" => [segment]}
    Map.merge(%{"id" => id, "name" => id, "applies" => "always", "goals" => [], "entries" => [entry], "refresh" => []}, extra)
  end

  defp state(sections) do
    gifts = [%{id: "g_one", name: "One", tier: 2, selling_cost: 30}, %{id: "g_two", name: "Two", tier: 2, selling_cost: 30}]

    %{
      plan: %{"sections" => sections},
      floor: 1,
      shop_type: :normal,
      reserve: 0,
      refreshes: 0,
      replaced: MapSet.new(),
      sold: %{},
      bought: %{},
      healed: %{},
      gifts_by_name: Map.new(gifts, &{&1.name, &1}),
      gifts_by_id: Map.new(gifts, &{&1.id, &1}),
      protected: MapSet.new(),
      sell_popup_open: false,
      heal_menu_open: false,
      last_heal: nil,
      left: false,
      steps: []
    }
  end

  setup do
    {:ok, pid} = RunMemory.start_link()
    ctx = Ctx.new(run_memory: pid)
    RunMemory.put_cost(ctx, 300)
    %{ctx: ctx}
  end

  defp next_section_ids({:steps, [{:call, {ShopRunner, :work, [rest, _state, :dry_run]}}]}), do: Enum.map(rest, & &1["id"])

  test "an unreached section hands the remaining sections to the next step", %{ctx: ctx} do
    sections = [section("first", "One"), section("second", "Two")]

    result = ShopRunner.work(sections, state(sections), :dry_run, nil, ctx)

    assert next_section_ids(result) == ["second"]
  end

  test "a pursue-optional section drops everything after it", %{ctx: ctx} do
    sections = [section("first", "One", %{"pursue_optional" => true}), section("second", "Two")]

    result = ShopRunner.work(sections, state(sections), :dry_run, nil, ctx)

    assert next_section_ids(result) == []
  end

  test "a pursue-optional section with nothing left to own still runs instead of being skipped", %{ctx: ctx} do
    sections = [section("first", "One", %{"pursue_optional" => true}), section("second", "Two")]
    RunMemory.add_ego_gift(ctx, "g_one", "One")

    {:steps, [{:call, {ShopRunner, :work, [[], final, :dry_run]}}]} = ShopRunner.work(sections, state(sections), :dry_run, nil, ctx)

    assert [%{id: "first", outcome: outcome}] = final.steps
    assert outcome != :skipped
  end

  defp with_heal(section) do
    segment = Map.merge(GiftPlans.default_segment(), %{"disposition" => "ignore", "goal" => nil, "buy" => false, "sinners" => [], "repeat" => "once"})
    heal = %{"id" => "me_heal_" <> section["id"], "subject" => %{"action" => "heal_all"}, "fusion" => nil, "floors" => [segment]}
    Map.update!(section, "entries", &(&1 ++ [heal]))
  end

  defp recorded({:steps, [{:call, {ShopRunner, :work, [_rest, state, :dry_run]}}]}), do: Map.new(state.steps, &{&1.id, &1})

  describe "healing for sections that are already reached" do
    test "is skipped while a later section is still unreached", %{ctx: ctx} do
      sections = [with_heal(section("first", "One")), section("second", "Two")]
      RunMemory.add_ego_gift(ctx, "g_one", "One")

      steps = sections |> then(&ShopRunner.work(&1, state(&1), :dry_run, nil, ctx)) |> recorded()

      assert steps["first"].outcome == :skipped
      refute steps["first"].detail =~ "only healing"
    end

    test "runs heal-only once every later section is reached too", %{ctx: ctx} do
      sections = [with_heal(section("first", "One")), section("second", "Two")]
      RunMemory.add_ego_gift(ctx, "g_one", "One")
      RunMemory.add_ego_gift(ctx, "g_two", "Two")

      steps = sections |> then(&ShopRunner.work(&1, state(&1), :dry_run, nil, ctx)) |> recorded()

      assert steps["first"].outcome == :would_run
      assert steps["first"].detail =~ "only healing"
    end

    test "runs heal-only when the later section pursues optional gifts and its goals are met", %{ctx: ctx} do
      sections = [with_heal(section("first", "One")), section("second", "Two", %{"pursue_optional" => true})]
      RunMemory.add_ego_gift(ctx, "g_one", "One")
      RunMemory.add_ego_gift(ctx, "g_two", "Two")

      steps = sections |> then(&ShopRunner.work(&1, state(&1), :dry_run, nil, ctx)) |> recorded()

      assert steps["first"].outcome == :would_run
      assert steps["first"].detail =~ "only healing"
    end

    test "is skipped when the later section pursues optional gifts and its goals are not met", %{ctx: ctx} do
      sections = [with_heal(section("first", "One")), section("second", "Two", %{"pursue_optional" => true})]
      RunMemory.add_ego_gift(ctx, "g_one", "One")

      steps = sections |> then(&ShopRunner.work(&1, state(&1), :dry_run, nil, ctx)) |> recorded()

      assert steps["first"].outcome == :skipped
    end
  end
end
