defmodule StarlightBotWeb.Live.TeamEditorLive do
  use StarlightBotWeb, :live_view

  alias StarlightBot.{GiftPlans, StarlightBudget, Strategies, Teams, ThemePacks}
  alias StarlightBotWeb.Live.GiftPlanEditorLive
  alias StarlightBot.Navigation.Navigator

  @gift_affinities ~w(burn bleed tremor rupture sinking poise charge)
  @countdown_secs 2

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Navigator.subscribe()
    nav = Navigator.status()

    {:ok,
     socket
     |> assign(:teams, Teams.list_teams())
     |> assign(:gift_strategies, Strategies.list(:gift_strategies))
     |> assign(:battle_strategies, Strategies.list(:battle_strategies))
     |> assign(:theme_pack_plans, Strategies.list(:theme_pack_plans))
     |> assign(:team_hooks, Teams.team_hooks())
     |> assign(:theme_packs, ThemePacks.list_theme_packs())
     |> assign(:gift_affinities, @gift_affinities)
     |> assign(:form, blank_form())
     |> assign(:editing_id, nil)
     |> assign(:hooks, [])
     |> assign(:active, false)
     |> assign(:selected_ids, blank_selected_ids())
     |> assign(:strategy_forms, blank_strategy_forms())
     |> assign(:budget_inputs, blank_budget_inputs())
     |> assign(:phase, nav.phase)
     |> assign(:log, nav.log)
     |> assign(:pending_action, nil)
     |> assign(:countdown, nil)}
  end

  @impl true
  def handle_event("new_team", _, socket) do
    case Teams.create_default_team() do
      {:ok, id} ->
        {:noreply,
         socket
         |> assign(:teams, Teams.list_teams())
         |> load_team(id)
         |> put_flash(:info, "Team created.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("duplicate_team", %{"id" => id}, socket) do
    case Teams.duplicate_team(String.to_integer(id)) do
      {:ok, new_id} ->
        {:noreply,
         socket
         |> assign(:teams, Teams.list_teams())
         |> load_team(new_id)
         |> put_flash(:info, "Team duplicated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Duplicate failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("edit_team", %{"id" => id}, socket) do
    {:noreply, load_team(socket, String.to_integer(id))}
  end

  @impl true
  def handle_event("validate_team", %{"team" => params}, socket) do
    socket = assign(socket, :form, build_form(params))
    name = String.trim(params["name"] || "")

    if name == "" do
      {:noreply, socket}
    else
      case Teams.save_team(team_attrs(socket, name)) do
        {:ok, _id} -> {:noreply, assign(socket, :teams, Teams.list_teams())}
        {:error, reason} -> {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("add_team_hook", %{"hook" => hook}, socket) do
    if hook == "" or hook in socket.assigns.hooks do
      {:noreply, socket}
    else
      {:noreply, socket |> assign(:hooks, socket.assigns.hooks ++ [hook]) |> persist_team()}
    end
  end

  @impl true
  def handle_event("remove_team_hook", %{"index" => index}, socket) do
    {:noreply, socket |> assign(:hooks, List.delete_at(socket.assigns.hooks, String.to_integer(index))) |> persist_team()}
  end

  @impl true
  def handle_event("reorder_team_hooks", %{"ids" => ids}, socket) do
    hooks = socket.assigns.hooks
    order = Enum.map(ids, &String.to_integer/1)

    if Enum.sort(order) == Enum.to_list(0..(length(hooks) - 1)//1) do
      {:noreply, socket |> assign(:hooks, Enum.map(order, &Enum.at(hooks, &1))) |> persist_team()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_team", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Teams.delete_team(id) do
      {:ok, _} ->
        socket = if socket.assigns.editing_id == id, do: reset_editor(socket), else: socket

        {:noreply,
         socket
         |> assign(:teams, Teams.list_teams())
         |> put_flash(:info, "Team deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("select_strategy", %{"kind" => kind, "id" => id}, socket) do
    socket =
      socket
      |> update(:selected_ids, &Map.put(&1, kind, parse_id(id)))
      |> persist_team()

    {:noreply, socket}
  end

  @impl true
  def handle_event("budget_change", params, socket) do
    inputs = %{
      pack_searches: parse_id(params["pack_searches"]),
      sinner_bonus: parse_id(params["sinner_bonus"]) || 0,
      railway_packs: parse_id(params["railway_packs"]),
      reward_cards: parse_id(params["reward_cards"]) || 0
    }

    {:noreply, assign(socket, :budget_inputs, inputs)}
  end

  @impl true
  def handle_event("toggle_new_strategy", %{"kind" => kind}, socket) do
    {:noreply, update(socket, :strategy_forms, &Map.update!(&1, kind, fn open -> not open end))}
  end

  @impl true
  def handle_event("save_strategy", %{"kind" => kind, "name" => name} = params, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, put_flash(socket, :error, "Strategy name is required.")}
    else
      table = kind_table(kind)
      data = strategy_data(kind, params)

      case Strategies.save(table, %{name: name, data: data}) do
        {:ok, id} ->
          {:noreply,
           socket
           |> assign(table, Strategies.list(table))
           |> update(:selected_ids, &Map.put(&1, kind, id))
           |> update(:strategy_forms, &Map.put(&1, kind, false))
           |> persist_team()
           |> put_flash(:info, "'#{name}' saved.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("select_team_on_screen", %{"id" => id}, socket) do
    id = String.to_integer(id)
    team = Enum.find(socket.assigns.teams, &(&1.id == id))
    {:noreply, start_countdown(socket, {:select_team_on_screen, id, team && team.name})}
  end

  @impl true
  def handle_event("cancel_pending", _, socket) do
    {:noreply, socket |> assign(:pending_action, nil) |> assign(:countdown, nil)}
  end

  @impl true
  def handle_info(:countdown_tick, %{assigns: %{pending_action: nil}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:countdown_tick, %{assigns: %{countdown: 1, pending_action: action}} = socket) do
    run_pending_action(action)
    {:noreply, socket |> assign(:pending_action, nil) |> assign(:countdown, nil)}
  end

  @impl true
  def handle_info(:countdown_tick, socket) do
    Process.send_after(self(), :countdown_tick, 1_000)
    {:noreply, assign(socket, :countdown, socket.assigns.countdown - 1)}
  end

  @impl true
  def handle_info({:nav_state, nav}, socket) do
    {:noreply, socket |> assign(:phase, nav.phase) |> assign(:log, nav.log)}
  end

  # --- Private ---

  defp start_countdown(socket, action) do
    Process.send_after(self(), :countdown_tick, 1_000)

    socket
    |> assign(:pending_action, action)
    |> assign(:countdown, @countdown_secs)
  end

  defp run_pending_action({:select_team_on_screen, id, _name}), do: Navigator.select_team_on_screen(id)

  def pending_action_label({:select_team_on_screen, _id, name}), do: "select on screen: #{name || "team"}"

  def log_kind_class(:ok), do: "text-success"
  def log_kind_class(:error), do: "text-error"
  def log_kind_class(:info), do: "text-base-content/60"
  def log_kind_class(_), do: "text-base-content/40"

  defp team_attrs(socket, name) do
    sel = socket.assigns.selected_ids

    %{
      id: socket.assigns.editing_id,
      name: name,
      hooks: socket.assigns.hooks,
      gift_strategy_id: sel["gift_strategy"],
      battle_strategy_id: sel["battle_strategy"],
      theme_pack_plan_id: sel["theme_pack_plan"]
    }
  end

  defp persist_team(%{assigns: %{editing_id: nil}} = socket), do: socket

  defp persist_team(socket) do
    attrs = team_attrs(socket, socket.assigns.form[:name].value)

    case Teams.save_team(attrs) do
      {:ok, _id} -> assign(socket, :teams, Teams.list_teams())
      {:error, reason} -> put_flash(socket, :error, "Save failed: #{inspect(reason)}")
    end
  end

  defp load_team(socket, id) do
    case Teams.get_team(id) do
      nil ->
        put_flash(socket, :error, "Team not found.")

      team ->
        socket
        |> assign(:form, build_form(%{"name" => team.name}))
        |> assign(:editing_id, team.id)
        |> assign(:hooks, team.hooks)
        |> assign(:active, true)
        |> assign(:selected_ids, %{
          "gift_strategy" => team.gift_strategy_id,
          "battle_strategy" => team.battle_strategy_id,
          "theme_pack_plan" => team.theme_pack_plan_id
        })
        |> assign(:strategy_forms, blank_strategy_forms())
        |> assign(:budget_inputs, blank_budget_inputs())
    end
  end

  defp reset_editor(socket) do
    socket
    |> assign(:form, blank_form())
    |> assign(:editing_id, nil)
    |> assign(:hooks, [])
    |> assign(:active, false)
    |> assign(:selected_ids, blank_selected_ids())
    |> assign(:strategy_forms, blank_strategy_forms())
  end

  defp blank_selected_ids do
    %{"gift_strategy" => nil, "battle_strategy" => nil, "theme_pack_plan" => nil}
  end

  defp blank_budget_inputs do
    %{pack_searches: 1, sinner_bonus: div(StarlightBudget.max_sinner_bonus(), 2), railway_packs: nil, reward_cards: 0}
  end

  def starlight_budget(gift_strategies, theme_pack_plans, theme_packs, selected_ids, inputs) do
    gift_data = strategy_data_for(gift_strategies, selected_ids["gift_strategy"])
    plan_data = strategy_data_for(theme_pack_plans, selected_ids["theme_pack_plan"])
    floors = StarlightBudget.floor_rewards(plan_data["mode_schedule"] || [])
    floor_total = floors |> Enum.map(& &1.starlight) |> Enum.sum()
    max_pack_searches = StarlightBudget.max_pack_searches(plan_data)
    pack_searches = min(inputs.pack_searches || max_pack_searches, max_pack_searches)
    max_railway_packs = length(StarlightBudget.railway_floors(plan_data, theme_packs, ~w(hunt bonus fine)))
    planned_railway_packs = length(StarlightBudget.railway_floors(plan_data, theme_packs, ~w(hunt bonus)))
    railway_packs = min(inputs.railway_packs || planned_railway_packs, max_railway_packs)
    gift_searches = length(gift_data["gift_search"] || [])

    income = %{
      base: StarlightBudget.base(),
      sinner_bonus: inputs.sinner_bonus,
      exploration: StarlightBudget.exploration_gain(floor_total, railway_packs, inputs.sinner_bonus),
      cards: StarlightBudget.cards_gain(inputs.reward_cards)
    }

    costs = %{
      grace: if(gift_data == %{}, do: 0, else: GiftPlanEditorLive.grace_total_cost(GiftPlans.normalize(gift_data))),
      gift_search: GiftPlans.gift_search_starlight_cost(gift_searches),
      pack_search: StarlightBudget.pack_search_cost(pack_searches)
    }

    %{
      income: income,
      costs: costs,
      floors: floors,
      floor_total: floor_total,
      railway_packs: railway_packs,
      max_railway_packs: max_railway_packs,
      rest_multiplier: StarlightBudget.rest_multiplier_milli(inputs.sinner_bonus) / 1000,
      reward_cards: inputs.reward_cards,
      gift_searches: gift_searches,
      pack_searches: pack_searches,
      max_pack_searches: max_pack_searches,
      has_gift_strategy?: gift_data != %{},
      has_theme_pack_plan?: plan_data != %{},
      net: Enum.sum(Map.values(income)) - Enum.sum(Map.values(costs))
    }
  end

  defp strategy_data_for(strategies, id), do: Enum.find_value(strategies, %{}, &(&1.id == id && &1.data)) || %{}

  def floor_breakdown(floors), do: Enum.map_join(floors, ", ", &"F#{&1.floor} #{&1.mode} #{&1.starlight}")

  defp blank_strategy_forms do
    %{"gift_strategy" => false, "theme_pack_plan" => false}
  end

  defp blank_form, do: build_form(%{})

  defp build_form(params) do
    types = %{name: :string}

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(params, Map.keys(types))
      |> Ecto.Changeset.validate_required([:name])

    to_form(changeset, as: :team)
  end

  defp kind_table("gift_strategy"), do: :gift_strategies
  defp kind_table("theme_pack_plan"), do: :theme_pack_plans

  defp strategy_data("gift_strategy", params), do: GiftPlans.blank(params["affinity"])
  defp strategy_data("theme_pack_plan", _params), do: %{version: 1, mode_schedule: [], packs: %{}}

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil

  defp parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp missing_label(:hook), do: "team selector"
  defp missing_label(:gift_strategy), do: "gift strategy"
  defp missing_label(:battle_strategy), do: "battle strategy"
  defp missing_label(:lineup), do: "lineup (set it up in the battle strategy)"
  defp missing_label(:theme_pack_plan), do: "theme pack plan"
end
