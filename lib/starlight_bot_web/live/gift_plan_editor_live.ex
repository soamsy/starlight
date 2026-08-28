defmodule StarlightBotWeb.Live.GiftPlanEditorLive do
  use StarlightBotWeb, :live_view

  alias StarlightBot.{EgoGifts, Strategies, Teams}

  @priorities ~w(essential desired opportunistic)
  @tabs ~w(buy fusion uptie keep skills refresh grace)a
  @fusable_tiers 1..4
  @gift_tiers 1..6
  @affinities ~w(bleed blunt burn charge pierce poise rupture sinking slash tremor)
  @gift_sorts ~w(default name tier affinity)
  @uptie_levels ["0->1", "0->2"]
  @uptie_costs %{
    1 => %{"0->1" => 50, "0->2" => 150},
    2 => %{"0->1" => 60, "0->2" => 180},
    3 => %{"0->1" => 75, "0->2" => 225},
    4 => %{"0->1" => 100, "0->2" => 300}
  }
  @ingredient_sources ~w(buy_if_short junk_only)
  @uptie_views ~w(base uptie2 uptie3)
  @stat_codes %{"cp" => "Clash Power", "fc" => "Final Power", "bc" => "Base Power", "cg" => "Coin Count"}

  @graces [
    %{index: 0, name: "Star of the Beginning", base_cost: 10,
      effects: %{
        0 => "Starting Cost +150. Theme Pack Selection +1. Shop E.G.O Gift Selection +1. One free Normal Refresh for Shops.",
        1 => "Starting Cost +250. Theme Pack Selection +1. Shop E.G.O Gift Selection +1. One free Normal Refresh for Shops.",
        2 => "Starting Cost +250. Theme Pack Selection +1. Shop E.G.O Gift Selection +1. Two free Normal Refreshes for Shops."
      }},
    %{index: 1, name: "Cumulating Starcloud", base_cost: 10,
      effects: %{
        0 => "On floor advance, current Cost balance +10% (max 100). E.G.O Gift sale price +50% (once per Shop).",
        1 => "On floor advance, current Cost balance +20% (max 125). E.G.O Gift sale price +75% (once per Shop).",
        2 => "On floor advance, current Cost balance +30% (max 150). E.G.O Gift sale price +100% (once per Shop)."
      }},
    %{index: 2, name: "Interstellar Travel", base_cost: 20,
      effects: %{
        0 => "Theme Pack Selection +1. Theme Pack Refresh Chance +2. First new Theme Pack choice grants all Identities +3 Level (max 9).",
        1 => "Theme Pack Selection +1. Theme Pack Refresh Chance +3. First new Theme Pack choice grants all Identities +3 Level (max 9). Gain 1 Clash Power Up in Floor 5 or lower combat.",
        2 => "Theme Pack Selection +1. Theme Pack Refresh Chance +4. First new Theme Pack choice grants all Identities +3 Level (max 9). Gain 3 Clash Power Up in Floor 5 or lower combat."
      }},
    %{index: 3, name: "Star-shower", base_cost: 20,
      effects: %{
        0 => "Starting Cost +400. Starting E.G.O Gift Choice +1.",
        1 => "Starting Cost +500. Starting E.G.O Gift Choice +1. Cost +75 when choosing Starlight from Encounter Rewards.",
        2 => "Starting Cost +700. Starting E.G.O Gift Choice +1. Cost +150 when choosing Starlight from Encounter Rewards."
      }},
    %{index: 4, name: "Binary Star-shop", base_cost: 30,
      effects: %{
        0 => "Shop E.G.O Gift Selection +1. Encounter Reward Cost +20%. Higher chance of high-tier E.G.O Gifts in Shops.",
        1 => "Shop E.G.O Gift Selection +1. Encounter Reward Cost +30%. Higher chance of high-tier E.G.O Gifts in Shops. On entering a Shop, gain Cost equal to the sum of owned E.G.O Gift tiers (max 75).",
        2 => "Shop E.G.O Gift Selection +1. Encounter Reward Cost +40%. Higher chance of high-tier E.G.O Gifts in Shops. On entering a Shop, gain Cost equal to the sum of owned E.G.O Gift tiers (max 150)."
      }},
    %{index: 5, name: "Moon Star-shop", base_cost: 30,
      effects: %{
        0 => "One free Keyword Refresh for Shops. On entering Floor 1, gain 1 random Tier 1 E.G.O Gift.",
        1 => "One free Keyword Refresh for Shops. On entering Floor 1, gain 2 random Tier 1 E.G.O Gifts. +10% chance for a Super Shop to appear.",
        2 => "Two free Keyword Refreshes for Shops. On entering Floor 1, gain 3 random Tier 1 E.G.O Gifts. +25% chance for a Super Shop to appear."
      }},
    %{index: 6, name: "Favor of the Nebulae", base_cost: 40,
      effects: %{
        0 => "On entry, all Identities +3 Level. On floor clear, all Identities +1 Level (max 5).",
        1 => "On entry, all Identities +3 Level. On floor clear, all Identities +1 Level (max 9).",
        2 => "On entry, all Identities +3 Level. On floor clear, all Identities +1 Level (max 9). On entering Floor 6, all Identities +3 Level."
      }},
    %{index: 7, name: "Starlight Guidance", base_cost: 40,
      effects: %{
        0 => "Max Speed +2. Gain 1 Clash Power Up, 1 Damage Up, 1 Protection.",
        1 => "Max Speed +3. Gain 2 Clash Power Up, 1 Damage Up, 1 Protection.",
        2 => "Max Speed +3. Gain 2 Clash Power Up, 2 Damage Up, 2 Protection."
      }},
    %{index: 8, name: "Chance Comet", base_cost: 50,
      effects: %{
        0 => "On entering a Shop, gain 1 random Tier 3-or-less Fuse/Sale-only E.G.O Gift. On entering Floor 3, gain 1 random Tier 3 E.G.O Gift. When fusing, gain a random extra E.G.O Gift 2 tiers below the result (Tier 3+ only, once per Shop).",
        1 => "On entering a Shop, gain 1 random Tier 1-3 Fuse/Sale-only E.G.O Gift (Tier 2-3 on Floor 6+). On entering Floor 3 or 5, gain 1 random Tier 3 E.G.O Gift. When fusing, gain a random extra E.G.O Gift 2 tiers below the result (Tier 3+ only, once per Shop).",
        2 => "On entering a Shop, gain 1 random Tier 2-3 Fuse/Sale-only E.G.O Gift (Tier 3-4 on Floor 6+). On entering Floor 3, 5, or 7, gain 1 random Tier 4 E.G.O Gift. When fusing, gain a random extra E.G.O Gift 2 tiers below the result (Tier 3+ only, once per Shop)."
      }},
    %{index: 9, name: "Perfected Possibility", base_cost: 60,
      effects: %{
        0 => "Theme Pack Selection +1. Starting E.G.O Gift Choice +1. On entry, gain 1 Tier 3 E.G.O Gift of your choice for your selected Keyword category.",
        1 => "Theme Pack Selection +1. Starting E.G.O Gift Choice +1. On entry, gain 2 Tier 3 E.G.O Gifts of your choice for your selected Keyword category.",
        2 => "Theme Pack Selection +1. Starting E.G.O Gift Choice +1. On entry, gain 3 Tier 3 E.G.O Gifts of your choice for your selected Keyword category."
      }}
  ]

  @impl true
  def mount(_params, _session, socket) do
    gifts = EgoGifts.list_gifts()

    {:ok,
     socket
     |> assign(:plans, custom_plans(Strategies.list(:gift_strategies)))
     |> assign(:gifts, gifts)
     |> assign(:gifts_by_name, Map.new(gifts, &{&1.name, &1}))
     |> assign(:gifts_by_id, Map.new(gifts, &{&1.id, &1}))
     |> assign(:sinners, Teams.all_sinners())
     |> reset_editor()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Integer.parse(id) do
      {int_id, _} -> {:noreply, load_plan(socket, int_id)}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new_plan", _, socket) do
    attrs = %{name: new_plan_name(socket.assigns.plans), data: blank_plan_data()}

    case Strategies.save(:gift_strategies, attrs) do
      {:ok, id} ->
        {:noreply,
         socket
         |> assign(:plans, custom_plans(Strategies.list(:gift_strategies)))
         |> load_plan(id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("select_plan", %{"id" => id}, socket) do
    {:noreply, load_plan(socket, String.to_integer(id))}
  end

  @impl true
  def handle_event("duplicate_plan", %{"id" => id}, socket) do
    case Strategies.get(:gift_strategies, String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Plan not found.")}

      plan ->
        attrs = %{name: "#{plan.name} (copy)", data: plan.data}

        case Strategies.save(:gift_strategies, attrs) do
          {:ok, new_id} ->
            {:noreply,
             socket
             |> assign(:plans, custom_plans(Strategies.list(:gift_strategies)))
             |> load_plan(new_id)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Duplicate failed: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("delete_plan", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Strategies.delete(:gift_strategies, id) do
      {:ok, _} ->
        socket = if socket.assigns.editing_id == id, do: reset_editor(socket), else: socket

        {:noreply,
         socket
         |> assign(:plans, custom_plans(Strategies.list(:gift_strategies)))
         |> put_flash(:info, "Plan deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("rename_plan", %{"value" => name}, socket) do
    {:noreply, socket |> assign(:name, String.trim(name)) |> persist_plan()}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("filter_gifts", %{"value" => value}, socket) do
    {:noreply, assign(socket, :gift_filter, value)}
  end

  @impl true
  def handle_event("set_gift_tier_filter", %{"value" => tier}, socket) do
    tier = if tier == "", do: nil, else: String.to_integer(tier)
    {:noreply, assign(socket, :gift_tier_filter, tier)}
  end

  @impl true
  def handle_event("set_gift_affinity_filter", %{"value" => affinity}, socket) do
    affinity = if affinity == "", do: nil, else: affinity
    {:noreply, assign(socket, :gift_affinity_filter, affinity)}
  end

  @impl true
  def handle_event("set_gift_sort", %{"value" => sort_by}, socket) when sort_by in @gift_sorts do
    {:noreply, assign(socket, :gift_sort, sort_by)}
  end

  @impl true
  def handle_event("select_gift", %{"gift" => gift}, socket) do
    if socket.assigns.selected_gift_name == gift do
      {:noreply, assign(socket, :selected_gift_name, nil)}
    else
      {:noreply, socket |> assign(:selected_gift_name, gift) |> assign(:uptie_view, "base")}
    end
  end

  @impl true
  def handle_event("set_uptie_view", %{"level" => level}, socket) when level in @uptie_views do
    {:noreply, assign(socket, :uptie_view, level)}
  end

  @impl true
  def handle_event("toggle_grace", %{"index" => index}, socket) do
    index = String.to_integer(index)
    picks = socket.assigns.plan_data["grace_picks"]

    picks =
      if Enum.any?(picks, &(&1["index"] == index)) do
        Enum.reject(picks, &(&1["index"] == index))
      else
        [%{"index" => index, "enhance" => 0} | picks]
      end

    {:noreply,
     socket
     |> assign(:plan_data, Map.put(socket.assigns.plan_data, "grace_picks", picks))
     |> persist_plan()}
  end

  @impl true
  def handle_event("set_grace_enhance", %{"index" => index, "level" => level}, socket) do
    index = String.to_integer(index)
    level = String.to_integer(level)
    picks = socket.assigns.plan_data["grace_picks"]

    picks =
      if Enum.any?(picks, &(&1["index"] == index)) do
        Enum.map(picks, fn pick -> if pick["index"] == index, do: %{pick | "enhance" => level}, else: pick end)
      else
        [%{"index" => index, "enhance" => level} | picks]
      end

    {:noreply,
     socket
     |> assign(:plan_data, Map.put(socket.assigns.plan_data, "grace_picks", picks))
     |> persist_plan()}
  end

  @impl true
  def handle_event("toggle_keep", %{"gift" => gift}, socket) do
    keep = socket.assigns.plan_data["keep"]
    keep = if gift in keep, do: List.delete(keep, gift), else: [gift | keep]

    {:noreply,
     socket
     |> assign(:plan_data, Map.put(socket.assigns.plan_data, "keep", keep))
     |> persist_plan()}
  end

  @impl true
  def handle_event("assign_buy_weight", %{"gift" => gift, "weight" => weight}, socket) do
    entry = %{"gift" => gift, "weight" => parse_int(weight, 0)}

    buy_on_sight =
      [entry | Enum.reject(socket.assigns.plan_data["buy_on_sight"], &(&1["gift"] == gift))]

    {:noreply,
     socket
     |> assign(:plan_data, Map.put(socket.assigns.plan_data, "buy_on_sight", buy_on_sight))
     |> persist_plan()}
  end

  @impl true
  def handle_event("remove_buy_target", %{"gift" => gift}, socket) do
    buy_on_sight = Enum.reject(socket.assigns.plan_data["buy_on_sight"], &(&1["gift"] == gift))

    {:noreply,
     socket
     |> assign(:plan_data, Map.put(socket.assigns.plan_data, "buy_on_sight", buy_on_sight))
     |> persist_plan()}
  end

  @impl true
  def handle_event("add_fusion_target", %{"gift" => gift} = params, socket) when gift not in [nil, ""] do
    entry = %{
      "id" => new_id("ft"),
      "gift" => gift,
      "weight" => parse_int(params["weight"], 0),
      "ingredient_source" => params["ingredient_source"],
      "fallback_of" => blank_to_nil(params["fallback_of"])
    }

    fusion_targets = [entry | socket.assigns.plan_data["fusion_targets"]]

    {:noreply,
     socket
     |> assign(:plan_data, Map.put(socket.assigns.plan_data, "fusion_targets", fusion_targets))
     |> persist_plan()}
  end

  @impl true
  def handle_event("add_fusion_target", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select a gift to fuse toward first.")}
  end

  @impl true
  def handle_event("remove_fusion_target", %{"id" => id}, socket) do
    fusion_targets =
      socket.assigns.plan_data["fusion_targets"]
      |> Enum.reject(&(&1["id"] == id))
      |> Enum.map(fn t -> if t["fallback_of"] == id, do: Map.put(t, "fallback_of", nil), else: t end)

    {:noreply,
     socket
     |> assign(:plan_data, Map.put(socket.assigns.plan_data, "fusion_targets", fusion_targets))
     |> persist_plan()}
  end

  @impl true
  def handle_event("set_uptie_scope", %{"scope" => scope}, socket) do
    {:noreply, assign(socket, :uptie_scope, scope)}
  end

  @impl true
  def handle_event("add_uptie_target", params, socket) do
    entry =
      case params["scope"] do
        "named" ->
          %{"id" => new_id("ut"), "scope" => "named", "gift" => params["gift"],
            "target_level" => params["target_level"], "weight" => parse_int(params["weight"], 0)}

        "tier_affinity" ->
          %{"id" => new_id("ut"), "scope" => "tier_affinity", "tier" => String.to_integer(params["tier"]),
            "affinity" => params["affinity"], "target_level" => params["target_level"], "weight" => parse_int(params["weight"], 0)}
      end

    uptie_targets = [entry | socket.assigns.plan_data["uptie_targets"]]

    {:noreply,
     socket
     |> assign(:plan_data, Map.put(socket.assigns.plan_data, "uptie_targets", uptie_targets))
     |> persist_plan()}
  end

  @impl true
  def handle_event("remove_uptie_target", %{"id" => id}, socket) do
    uptie_targets = Enum.reject(socket.assigns.plan_data["uptie_targets"], &(&1["id"] == id))

    {:noreply,
     socket
     |> assign(:plan_data, Map.put(socket.assigns.plan_data, "uptie_targets", uptie_targets))
     |> persist_plan()}
  end

  @impl true
  def handle_event("add_skill_target", params, socket) do
    entry = %{
      "id" => new_id("st"),
      "sinner" => params["sinner"],
      "target_level" => String.to_integer(params["target_level"]),
      "priority" => params["priority"],
      "allow_search" => params["allow_search"] == "true"
    }

    skill_targets = [entry | socket.assigns.plan_data["skill_targets"]]

    {:noreply,
     socket
     |> assign(:plan_data, Map.put(socket.assigns.plan_data, "skill_targets", skill_targets))
     |> persist_plan()}
  end

  @impl true
  def handle_event("remove_skill_target", %{"id" => id}, socket) do
    skill_targets = Enum.reject(socket.assigns.plan_data["skill_targets"], &(&1["id"] == id))

    {:noreply,
     socket
     |> assign(:plan_data, Map.put(socket.assigns.plan_data, "skill_targets", skill_targets))
     |> persist_plan()}
  end

  @impl true
  def handle_event("update_refresh_policy", params, socket) do
    policy = %{
      "allow_affinity_refresh" => params["allow_affinity_refresh"] == "true",
      "max_normal_refreshes" => parse_int(params["max_normal_refreshes"], 0),
      "max_affinity_refreshes" => parse_int(params["max_affinity_refreshes"], 0)
    }

    {:noreply,
     socket
     |> assign(:plan_data, Map.put(socket.assigns.plan_data, "refresh_policy", policy))
     |> persist_plan()}
  end

  # --- Display helpers (used from the template) ---

  def priorities, do: @priorities
  def tabs, do: @tabs
  def graces, do: @graces

  def grace_pick(plan_data, index), do: Enum.find(plan_data["grace_picks"], &(&1["index"] == index))

  def grace_enhance_icon(0), do: "○"
  def grace_enhance_icon(1), do: "+"
  def grace_enhance_icon(2), do: "++"

  def grace_level_cost(grace, level), do: grace.base_cost * (level + 1)

  def grace_effect(grace, level), do: Map.get(grace.effects, level, Map.get(grace.effects, 0))

  def grace_total_cost(plan_data) do
    Enum.reduce(plan_data["grace_picks"], 0, fn pick, acc ->
      case Enum.find(@graces, &(&1.index == pick["index"])) do
        nil -> acc
        grace -> acc + grace_level_cost(grace, pick["enhance"])
      end
    end)
  end
  def fusable_tiers, do: @fusable_tiers
  def gift_tiers, do: @gift_tiers
  def affinities, do: @affinities
  def uptie_levels, do: @uptie_levels
  def ingredient_sources, do: @ingredient_sources

  def tab_label(:grace), do: "Grace"
  def tab_label(:keep), do: "Keep"
  def tab_label(:buy), do: "Buy on Sight"
  def tab_label(:fusion), do: "Fusion"
  def tab_label(:uptie), do: "Uptie"
  def tab_label(:skills), do: "Skills"
  def tab_label(:refresh), do: "Refresh"

  def priority_label("essential"), do: "Essential"
  def priority_label("desired"), do: "Desired"
  def priority_label("opportunistic"), do: "Opportunistic"

  def priority_tooltip("essential"), do: "Chase this aggressively — spend cost freely to get it."
  def priority_tooltip("desired"), do: "Worth going for, but don't sacrifice the essentials to get it."
  def priority_tooltip("opportunistic"), do: "Only take it if it's already cheap and available — never chase it."

  def ingredient_source_label("buy_if_short"), do: "Buy if short"
  def ingredient_source_label("junk_only"), do: "Junk only"

  def sinner_label(sinner) do
    sinner |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)
  end

  def buy_gifts_sorted(gifts_by_name, buy_on_sight) do
    buy_on_sight
    |> Enum.map(fn entry -> {Map.get(gifts_by_name, entry["gift"]), entry["weight"] || 0} end)
    |> Enum.reject(fn {gift, _weight} -> is_nil(gift) end)
    |> Enum.sort_by(fn {_gift, weight} -> -weight end)
  end

  def sort_by_weight(entries), do: Enum.sort_by(entries, &(-(&1["weight"] || 0)))

  def group_by_priority(entries) do
    Map.new(@priorities, fn p -> {p, Enum.filter(entries, &(&1["priority"] == p))} end)
  end

  def filtered_gifts(gifts, filter, tier_filter, affinity_filter, sort_by) do
    gifts
    |> Enum.filter(&matches_text_filter?(&1, filter))
    |> Enum.filter(&(is_nil(tier_filter) or &1.tier == tier_filter))
    |> Enum.filter(&(is_nil(affinity_filter) or &1.affinity == affinity_filter))
    |> sort_gifts(sort_by)
  end

  def gift_sorts, do: @gift_sorts

  def gift_sort_label("default"), do: "Default order"
  def gift_sort_label("name"), do: "Name"
  def gift_sort_label("tier"), do: "Tier"
  def gift_sort_label("affinity"), do: "Affinity"

  def sort_gifts(gifts, "name"), do: Enum.sort_by(gifts, &{&1.name || "", &1.tier || 0, &1.affinity || ""})
  def sort_gifts(gifts, "tier"), do: Enum.sort_by(gifts, &{&1.tier || 0, &1.affinity || ""})
  def sort_gifts(gifts, "affinity"), do: Enum.sort_by(gifts, &{&1.affinity || "", &1.tier || 0})
  def sort_gifts(gifts, _default), do: Enum.sort_by(gifts, &(&1.sort_id || 999_999))

  @roman_numerals [{5, "V"}, {4, "IV"}, {1, "I"}]

  def gift_tier_roman(nil), do: ""
  def gift_tier_roman(n) when is_integer(n), do: to_roman(n, @roman_numerals)

  defp to_roman(0, _table), do: ""
  defp to_roman(n, [{value, numeral} | rest]) when n >= value, do: numeral <> to_roman(n - value, [{value, numeral} | rest])
  defp to_roman(n, [_ | rest]), do: to_roman(n, rest)
  defp to_roman(_n, []), do: ""

  def gift_affinity_icon(affinity), do: "/images/affinity/#{affinity}.webp"

  def buy_weight_for(plan_data, gift_name) do
    case Enum.find(plan_data["buy_on_sight"], &(&1["gift"] == gift_name)) do
      %{"weight" => weight} -> weight
      nil -> nil
    end
  end

  def fusion_target_label(target, gifts_by_name) do
    case Map.get(gifts_by_name, target["gift"]) do
      %{name: name} -> name
      nil -> target["gift"] || legacy_fusion_target_label(target)
    end
  end

  defp legacy_fusion_target_label(%{"target_tier" => tier, "target_affinity" => affinity}),
    do: "T#{tier} · #{affinity} (legacy)"

  defp legacy_fusion_target_label(_), do: "?"

  def fusion_target_tier(target, gifts_by_name) do
    case Map.get(gifts_by_name, target["gift"]) do
      %{tier: tier} -> tier
      nil -> nil
    end
  end

  def fusion_ingredient_ids(%{ingredients: ingredients}) when is_binary(ingredients) and ingredients != "" do
    ingredients |> String.split(",") |> Enum.map(&String.trim/1)
  end

  def fusion_ingredient_ids(_gift), do: []

  def fusion_is_named_recipe?(target, gifts_by_name) do
    case Map.get(gifts_by_name, target["gift"]) do
      %{} = gift -> fusion_ingredient_ids(gift) != []
      nil -> false
    end
  end

  def fallback_label(nil, _fusion_targets, _gifts_by_name), do: nil

  def fallback_label(fallback_of, fusion_targets, gifts_by_name) do
    case Enum.find(fusion_targets, &(&1["id"] == fallback_of)) do
      nil -> nil
      target -> fusion_target_label(target, gifts_by_name)
    end
  end

  def uptie_target_label(%{"scope" => "named"} = target), do: target["gift"]
  def uptie_target_label(%{"scope" => "tier_affinity"} = target), do: "T#{target["tier"]} · #{target["affinity"]}"

  def uptie_target_tier(%{"scope" => "named", "gift" => gift}, gifts_by_name) do
    case Map.get(gifts_by_name, gift) do
      %{tier: tier} -> tier
      nil -> nil
    end
  end

  def uptie_target_tier(%{"scope" => "tier_affinity", "tier" => tier}, _gifts_by_name), do: tier
  def uptie_target_tier(_target, _gifts_by_name), do: nil

  def uptie_target_cost(target, gifts_by_name) do
    with tier when not is_nil(tier) <- uptie_target_tier(target, gifts_by_name),
         %{} = costs_by_tier <- Map.get(@uptie_costs, tier),
         cost when not is_nil(cost) <- Map.get(costs_by_tier, target["target_level"]) do
      cost
    else
      _ -> nil
    end
  end

  def uptie_views, do: @uptie_views

  def uptie_view_icon("base"), do: "○"
  def uptie_view_icon("uptie2"), do: "+"
  def uptie_view_icon("uptie3"), do: "++"

  def uptie_view_available?(gift, "base", gifts_by_id), do: not is_nil(clean_gift_text(gift.description, gifts_by_id))
  def uptie_view_available?(gift, "uptie2", gifts_by_id), do: not is_nil(clean_gift_text(gift.uptie2, gifts_by_id))
  def uptie_view_available?(gift, "uptie3", gifts_by_id), do: not is_nil(clean_gift_text(gift.uptie3, gifts_by_id))

  def gift_detail_text(gift, "base", gifts_by_id),
    do: clean_gift_text(gift.description, gifts_by_id) || "No description available."

  def gift_detail_text(gift, "uptie2", gifts_by_id),
    do: clean_gift_text(gift.uptie2, gifts_by_id) || "No + uptie change."

  def gift_detail_text(gift, "uptie3", gifts_by_id),
    do: clean_gift_text(gift.uptie3, gifts_by_id) || "No ++ uptie change."

  def clean_gift_text(nil, _gifts_by_id), do: nil

  def clean_gift_text(text, gifts_by_id) do
    text
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/?span[^>]*>/i, "")
    |> String.replace(~r/\$\[([^\]]*)\]\$+\s*/, "[\\1] ")
    |> replace_entity_tokens(gifts_by_id)
    |> replace_stat_tokens()
    |> String.replace("#", "")
    |> String.trim()
    |> case do
      "" -> nil
      cleaned -> cleaned
    end
  end

  # --- Private ---

  defp replace_entity_tokens(text, gifts_by_id) do
    text
    |> replace_regex(~r/&(ids|egos)_(\d+)&/, fn
      _, "ids", id -> "[Identity ##{id}]"
      _, "egos", id -> "[E.G.O ##{id}]"
    end)
    |> replace_regex(~r/@(gift_\d+)@/, fn _, id ->
      case Map.get(gifts_by_id, id) do
        %{name: name} -> "[→ #{name}]"
        nil -> "[Gift ##{id}]"
      end
    end)
  end

  defp replace_regex(text, regex, fun), do: Regex.replace(regex, text, fun)

  defp replace_stat_tokens(text) do
    Regex.replace(~r/&\s*([+-]?\d*)\s*([a-zA-Z]{2,3})\s*([+-]?\d*)\s*&/, text, fn _, lead, code, trail ->
      label = Map.get(@stat_codes, String.downcase(code), String.upcase(code))

      case pick_number(lead, trail) do
        nil -> label
        number -> "#{label} #{number}"
      end
    end)
  end

  defp pick_number(lead, trail) do
    cond do
      lead =~ ~r/\d/ -> lead
      trail =~ ~r/\d/ -> trail
      true -> nil
    end
  end

  defp matches_text_filter?(_gift, ""), do: true
  defp matches_text_filter?(gift, filter), do: String.contains?(String.downcase(gift.name || ""), String.downcase(filter))

  defp custom_plans(plans), do: Enum.filter(plans, &(get_in(&1.data, ["type"]) == "custom"))

  defp reset_editor(socket) do
    socket
    |> assign(:editing_id, nil)
    |> assign(:name, "")
    |> assign(:plan_data, blank_plan_data())
    |> assign(:active_tab, :buy)
    |> assign(:gift_filter, "")
    |> assign(:gift_tier_filter, nil)
    |> assign(:gift_affinity_filter, nil)
    |> assign(:gift_sort, "default")
    |> assign(:uptie_scope, "named")
    |> assign(:selected_gift_name, nil)
    |> assign(:uptie_view, "base")
  end

  defp load_plan(socket, id) do
    case Strategies.get(:gift_strategies, id) do
      nil ->
        put_flash(socket, :error, "Plan not found.")

      plan ->
        socket
        |> assign(:editing_id, plan.id)
        |> assign(:name, plan.name)
        |> assign(:plan_data, normalize_plan_data(plan.data))
        |> assign(:active_tab, :buy)
        |> assign(:gift_filter, "")
        |> assign(:gift_tier_filter, nil)
        |> assign(:gift_affinity_filter, nil)
        |> assign(:gift_sort, "default")
        |> assign(:uptie_scope, "named")
        |> assign(:selected_gift_name, nil)
        |> assign(:uptie_view, "base")
    end
  end

  defp persist_plan(socket) do
    attrs = %{id: socket.assigns.editing_id, name: socket.assigns.name, data: socket.assigns.plan_data}

    case Strategies.save(:gift_strategies, attrs) do
      {:ok, _id} -> assign(socket, :plans, custom_plans(Strategies.list(:gift_strategies)))
      {:error, reason} -> put_flash(socket, :error, "Save failed: #{inspect(reason)}")
    end
  end

  defp new_plan_name(plans), do: "New Gift Plan #{length(plans) + 1}"

  defp new_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  defp parse_int(val, default) do
    case Integer.parse(val || "") do
      {int, _} -> int
      :error -> default
    end
  end

  defp blank_plan_data do
    %{
      "version" => 1,
      "type" => "custom",
      "affinity" => nil,
      "grace_picks" => [
        %{"index" => 0, "enhance" => 0},
        %{"index" => 2, "enhance" => 0},
        %{"index" => 3, "enhance" => 0},
        %{"index" => 7, "enhance" => 0}
      ],
      "keep" => [],
      "buy_on_sight" => [],
      "fusion_targets" => [],
      "uptie_targets" => [],
      "skill_targets" => [],
      "refresh_policy" => %{
        "allow_affinity_refresh" => true,
        "max_normal_refreshes" => 1,
        "max_affinity_refreshes" => 0
      }
    }
  end

  defp normalize_plan_data(nil), do: blank_plan_data()

  defp normalize_plan_data(data) do
    data
    |> Map.put_new("type", "custom")
    |> Map.put_new("grace_picks", [])
    |> Map.update!("grace_picks", &normalize_grace_picks/1)
    |> Map.put_new("keep", [])
    |> Map.put_new("buy_on_sight", [])
    |> Map.put_new("fusion_targets", [])
    |> Map.put_new("uptie_targets", [])
    |> Map.put_new("skill_targets", [])
    |> Map.put_new("refresh_policy", blank_plan_data()["refresh_policy"])
  end

  defp normalize_grace_picks(picks) when is_list(picks) do
    Enum.map(picks, fn
      %{"index" => _, "enhance" => _} = pick -> pick
      index when is_integer(index) -> %{"index" => index, "enhance" => 0}
    end)
  end

  defp normalize_grace_picks(_), do: []

  # --- Function components ---

  attr :gifts, :list, required: true
  attr :gifts_by_id, :map, required: true
  attr :gift_filter, :string, required: true
  attr :gift_tier_filter, :any, required: true
  attr :gift_affinity_filter, :any, required: true
  attr :gift_sort, :string, required: true
  attr :selected_gift_name, :any, required: true
  attr :uptie_view, :string, required: true
  attr :show_fusion_info, :boolean, default: false
  slot :form, required: true

  def gift_browser(assigns) do
    ~H"""
    <div class="flex-1 min-h-0 flex flex-col gap-2">
      <div class="flex flex-col gap-1">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="text-xs font-medium text-base-content/70">Browse gifts</span>
          <input type="text" placeholder="Search gifts…" value={@gift_filter} phx-keyup="filter_gifts"
                 class="input input-bordered input-xs w-48" />
          <form phx-change="set_gift_tier_filter">
            <select name="value" class="select select-bordered select-xs">
              <option value="">any tier</option>
              <option :for={tier <- gift_tiers()} value={tier} selected={@gift_tier_filter == tier}>Tier <%= tier %></option>
            </select>
          </form>
          <form phx-change="set_gift_affinity_filter">
            <select name="value" class="select select-bordered select-xs">
              <option value="">any affinity</option>
              <option :for={affinity <- affinities()} value={affinity} selected={@gift_affinity_filter == affinity}><%= affinity %></option>
              <option disabled>──────────</option>
              <option value="none" selected={@gift_affinity_filter == "none"}>none</option>
            </select>
          </form>
          <form phx-change="set_gift_sort">
            <select name="value" class="select select-bordered select-xs">
              <option :for={sort_by <- gift_sorts()} value={sort_by} selected={@gift_sort == sort_by}>Sort: <%= gift_sort_label(sort_by) %></option>
            </select>
          </form>
        </div>

        <div class="grid gap-2 overflow-y-auto max-h-64 p-1" style="grid-template-columns: repeat(auto-fill, minmax(8.5rem, 1fr));">
          <div :for={gift <- filtered_gifts(@gifts, @gift_filter, @gift_tier_filter, @gift_affinity_filter, @gift_sort)}
               phx-click="select_gift" phx-value-gift={gift.name}
               class={"cursor-pointer flex items-center gap-1.5 p-1 rounded-lg " <>
                 if(@selected_gift_name == gift.name, do: "bg-primary/10", else: "hover:bg-base-200")}>
            <div class={"relative w-12 h-12 shrink-0 rounded-lg overflow-hidden bg-base-200 " <>
              if(@selected_gift_name == gift.name, do: "ring-2 ring-primary", else: "ring-1 ring-base-300")}>
              <img src={gift.image_path} class="w-full h-full object-cover" />
              <span :if={gift.tier} class="absolute top-0 left-0.5 font-black text-xs leading-none pointer-events-none"
                    style="font-family: ui-serif, Georgia, 'Times New Roman', serif; color: #fde047; text-shadow: -1px -1px 0 #7c2d12, 1px -1px 0 #7c2d12, -1px 1px 0 #7c2d12, 1px 1px 0 #7c2d12, 0 0 3px #f97316, 0 0 6px #ea580c;">
                <%= gift_tier_roman(gift.tier) %>
              </span>
              <img :if={gift.affinity not in [nil, "none"]} src={gift_affinity_icon(gift.affinity)} title={gift.affinity}
                   class="absolute bottom-0 right-0 w-3.5 h-3.5 object-contain drop-shadow" />
            </div>
            <span class="text-[10px] leading-tight line-clamp-3 flex-1 min-w-0" title={gift.name}><%= gift.name %></span>
          </div>
          <div :if={filtered_gifts(@gifts, @gift_filter, @gift_tier_filter, @gift_affinity_filter, @gift_sort) == []}
               class="col-span-full text-xs text-base-content/40 italic p-1">
            No matching gifts.
          </div>
        </div>
      </div>

      <div class="divider my-0"></div>

      <% selected = @selected_gift_name && Enum.find(@gifts, &(&1.name == @selected_gift_name)) %>
      <%= if selected do %>
        <div class="flex gap-2 border border-base-300 rounded-lg p-2">
          <div class="flex flex-col gap-2 flex-1 min-w-0">
            <div class="flex items-start gap-3">
              <img src={selected.image_path} class="w-16 h-16 rounded object-cover shrink-0" />
              <div class="flex flex-col gap-1 flex-1 min-w-0">
                <div class="text-sm font-semibold"><%= selected.name %></div>
                <div class="flex gap-1 flex-wrap">
                  <span class="badge badge-primary badge-xs">Tier <%= selected.tier %></span>
                  <span class="badge badge-ghost badge-xs"><%= selected.affinity %></span>
                  <span class="badge badge-ghost badge-xs"><%= selected.sin %></span>
                </div>
                <div class="text-xs text-base-content/70 flex gap-3">
                  <span>Buy: <%= selected.buying_cost || "—" %></span>
                  <span>Sell: <%= selected.selling_cost || "—" %></span>
                </div>
                <div :if={selected.obtain_method} class="text-[11px] text-base-content/50 truncate" title={selected.obtain_method}>
                  <%= selected.obtain_method %>
                </div>
              </div>
            </div>

            <div class="flex items-center gap-1">
              <button :for={level <- uptie_views()} type="button"
                      phx-click="set_uptie_view" phx-value-level={level}
                      disabled={not uptie_view_available?(selected, level, @gifts_by_id)}
                      class={"btn btn-2xs " <>
                        cond do
                          @uptie_view == level -> "btn-secondary"
                          not uptie_view_available?(selected, level, @gifts_by_id) -> "btn-outline btn-disabled"
                          true -> "btn-outline"
                        end}>
                <%= uptie_view_icon(level) %>
              </button>
              <span class="text-[10px] text-base-content/40">uptie</span>
            </div>
            <p class="text-xs whitespace-pre-line"><%= gift_detail_text(selected, @uptie_view, @gifts_by_id) %></p>

            <%= if @show_fusion_info do %>
              <div class="border-t border-base-300 pt-1 flex flex-col gap-1">
                <%= if fusion_ingredient_ids(selected) != [] do %>
                  <span class="text-[11px] font-medium text-base-content/70">Fixed recipe — requires:</span>
                  <div class="flex flex-wrap gap-1">
                    <%= for ing_id <- fusion_ingredient_ids(selected) do %>
                      <% ing = Map.get(@gifts_by_id, ing_id) %>
                      <span class="badge badge-outline badge-xs"><%= (ing && ing.name) || ing_id %></span>
                    <% end %>
                  </div>
                <% else %>
                  <span class="text-[11px] text-base-content/50">
                    No fixed recipe — obtained via tier-based fusion (combine lower-tier <%= selected.affinity %> gifts).
                  </span>
                <% end %>
              </div>
            <% end %>
          </div>

          <div class="w-56 shrink-0 border-l border-base-300 pl-2 flex flex-col gap-2">
            <%= render_slot(@form, selected) %>
          </div>
        </div>
      <% else %>
        <div class="text-xs text-base-content/40 italic">Select a gift above to add it to the plan.</div>
      <% end %>
    </div>
    """
  end

  attr :entries, :list, required: true
  slot :card, required: true

  def weight_list(assigns) do
    ~H"""
    <div class="border border-base-300 rounded-lg p-2 flex flex-col gap-1 min-h-24 max-h-72 overflow-y-auto">
      <%= for item <- @entries do %>
        <%= render_slot(@card, item) %>
      <% end %>
      <div :if={@entries == []} class="text-[11px] text-base-content/30 italic">none — sorted by weight, highest first</div>
    </div>
    """
  end

  attr :entries_by_priority, :map, required: true
  slot :card, required: true

  def priority_board(assigns) do
    ~H"""
    <div class="grid grid-cols-3 gap-2">
      <div :for={priority <- priorities()} class="border border-base-300 rounded-lg p-2 flex flex-col gap-1 min-h-24 max-h-72 overflow-y-auto">
        <div class="text-xs font-semibold text-base-content/70 flex items-center gap-1">
          <%= priority_label(priority) %>
          <span class="tooltip tooltip-bottom text-base-content/40 cursor-help" data-tip={priority_tooltip(priority)}>ⓘ</span>
        </div>
        <%= for item <- Map.get(@entries_by_priority, priority, []) do %>
          <%= render_slot(@card, item) %>
        <% end %>
        <div :if={Map.get(@entries_by_priority, priority, []) == []} class="text-[11px] text-base-content/30 italic">none</div>
      </div>
    </div>
    """
  end
end
