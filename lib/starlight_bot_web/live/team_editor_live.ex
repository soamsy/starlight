defmodule StarlightBotWeb.Live.TeamEditorLive do
  use StarlightBotWeb, :live_view

  alias StarlightBot.{Strategies, Teams}
  alias StarlightBot.Navigation.Navigator

  @sinners_row1 ~w(yi_sang faust don_quixote ryoshu meursault hong_lu)
  @sinners_row2 ~w(heathcliff ishmael rodion sinclair outis gregor)
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
     |> assign(:sinners_row1, @sinners_row1)
     |> assign(:sinners_row2, @sinners_row2)
     |> assign(:gift_affinities, @gift_affinities)
     |> assign(:form, blank_form())
     |> assign(:editing_id, nil)
     |> assign(:active, false)
     |> assign(:sinner_order, [])
     |> assign(:selected_ids, blank_selected_ids())
     |> assign(:strategy_forms, blank_strategy_forms())
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
  def handle_event("edit_team", %{"id" => id}, socket) do
    {:noreply, load_team(socket, String.to_integer(id))}
  end

  @impl true
  def handle_event("validate_team", %{"team" => params}, socket) do
    {:noreply, assign(socket, :form, build_form(params))}
  end

  @impl true
  def handle_event("save_team", %{"team" => params}, socket) do
    sel = socket.assigns.selected_ids

    attrs = %{
      id: socket.assigns.editing_id,
      name: String.trim(params["name"] || ""),
      hook: params["hook"],
      sinner_order: socket.assigns.sinner_order,
      gift_strategy_id: sel["gift_strategy"],
      battle_strategy_id: sel["battle_strategy"],
      theme_pack_plan_id: sel["theme_pack_plan"]
    }

    case Teams.save_team(attrs) do
      {:ok, id} ->
        {:noreply,
         socket
         |> assign(:teams, Teams.list_teams())
         |> assign(:editing_id, id)
         |> put_flash(:info, "Team '#{attrs.name}' saved.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
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
  def handle_event("toggle_sinner", %{"sinner" => sinner}, socket) do
    order = socket.assigns.sinner_order
    new_order = if sinner in order, do: List.delete(order, sinner), else: order ++ [sinner]
    {:noreply, assign(socket, :sinner_order, new_order)}
  end

  @impl true
  def handle_event("clear_sinner_order", _, socket) do
    {:noreply, assign(socket, :sinner_order, [])}
  end

  @impl true
  def handle_event("select_strategy", %{"kind" => kind, "id" => id}, socket) do
    {:noreply, update(socket, :selected_ids, &Map.put(&1, kind, parse_id(id)))}
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

  defp load_team(socket, id) do
    case Teams.get_team(id) do
      nil ->
        put_flash(socket, :error, "Team not found.")

      team ->
        params = %{"name" => team.name, "hook" => team.hook || ""}

        socket
        |> assign(:form, build_form(params))
        |> assign(:editing_id, team.id)
        |> assign(:active, true)
        |> assign(:sinner_order, team.sinner_order)
        |> assign(:selected_ids, %{
          "gift_strategy" => team.gift_strategy_id,
          "battle_strategy" => team.battle_strategy_id,
          "theme_pack_plan" => team.theme_pack_plan_id
        })
        |> assign(:strategy_forms, blank_strategy_forms())
    end
  end

  defp reset_editor(socket) do
    socket
    |> assign(:form, blank_form())
    |> assign(:editing_id, nil)
    |> assign(:active, false)
    |> assign(:sinner_order, [])
    |> assign(:selected_ids, blank_selected_ids())
    |> assign(:strategy_forms, blank_strategy_forms())
  end

  defp blank_selected_ids do
    %{"gift_strategy" => nil, "battle_strategy" => nil, "theme_pack_plan" => nil}
  end

  defp blank_strategy_forms do
    %{"gift_strategy" => false, "battle_strategy" => false, "theme_pack_plan" => false}
  end

  defp blank_form, do: build_form(%{})

  defp build_form(params) do
    types = %{name: :string, hook: :string}

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(params, Map.keys(types))
      |> Ecto.Changeset.validate_required([:name])

    to_form(changeset, as: :team)
  end

  defp kind_table("gift_strategy"), do: :gift_strategies
  defp kind_table("battle_strategy"), do: :battle_strategies
  defp kind_table("theme_pack_plan"), do: :theme_pack_plans

  defp strategy_data("gift_strategy", params), do: %{version: 1, type: "predefined", affinity: params["affinity"]}
  defp strategy_data("battle_strategy", params) do
    %{
      version: 2,
      mirror_dungeon: %{type: params["mirror_dungeon_type"] || "chain"},
      luxcavation: %{type: params["luxcavation_type"] || "chain"}
    }
  end
  defp strategy_data("theme_pack_plan", _params), do: %{version: 1, mode_schedule: [], packs: %{}}

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil

  defp parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp sinner_label(key) do
    key
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp sinner_position(order, sinner) do
    case Enum.find_index(order, &(&1 == sinner)) do
      nil -> nil
      idx -> idx + 1
    end
  end

  defp missing_label(:hook), do: "hook"
  defp missing_label(:sinner_order), do: "sinner order"
  defp missing_label(:gift_strategy), do: "gift strategy"
  defp missing_label(:battle_strategy), do: "battle strategy"
  defp missing_label(:theme_pack_plan), do: "theme pack plan"
end
