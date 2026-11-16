defmodule StarlightBotWeb.Components.TeamNav do
  use Phoenix.Component
  import StarlightBotWeb.Components.Icon, only: [icon: 1]
  use Phoenix.VerifiedRoutes, endpoint: StarlightBotWeb.Endpoint, router: StarlightBotWeb.Router

  import Phoenix.LiveView, only: [push_navigate: 2, push_patch: 2, put_flash: 3]
  alias Phoenix.LiveView.JS
  alias StarlightBot.{AppSettings, Hooks, PlanCounts, SinnerProfiles, TeamTemplates, Teams}

  @plan_panes ~w(battle packs gifts stats)
  @panes @plan_panes ++ ["profiles"]

  def init do
    build(stored_team_id(), stored_pane(), %{renaming_id: nil, editing_notes_id: nil, query: "", cursor: 0})
  end

  def reload(socket) do
    nav = socket.assigns.team_nav
    Phoenix.Component.assign(socket, :team_nav, build(nav.team_id, nav.pane, ui(nav)))
  end

  def handle_params(params, _uri, socket) do
    nav = socket.assigns.team_nav
    team_id = parse_id(params["team"])
    pane = if params["pane"] in @panes, do: params["pane"], else: nav.pane

    nav =
      if team_id && team_id != nav.team_id do
        build(team_id, pane, ui(nav))
      else
        %{nav | pane: pane}
      end

    nav = %{nav | query: "", cursor: Enum.find_index(nav.teams, &(&1.id == nav.team_id)) || 0}

    if team_id && nav.team_id == team_id, do: AppSettings.put("team_nav_team", Integer.to_string(team_id))
    if pane in @plan_panes, do: AppSettings.put("team_nav_pane", pane)

    {:cont, Phoenix.Component.assign(socket, :team_nav, nav)}
  end

  def handle_info(:team_plans_changed, socket), do: {:cont, reload(socket)}

  def handle_info({:plan_count, team_id, table, count}, %{assigns: %{team_nav: %{team_id: team_id} = nav}} = socket),
    do: {:cont, Phoenix.Component.assign(socket, :team_nav, %{nav | counts: Map.put(nav.counts, table, count)})}

  def handle_info(_msg, socket), do: {:cont, socket}

  def handle_event("team_nav_select", %{"id" => id}, socket), do: {:halt, select(socket, to_id(id))}

  def handle_event("team_nav_open", _params, socket) do
    nav = socket.assigns.team_nav
    {:halt, push_navigate(socket, to: team_path(nav.team_id, plan_pane(nav.pane)))}
  end

  def handle_event("team_nav_search_open", _params, socket) do
    nav = socket.assigns.team_nav
    cursor = Enum.find_index(nav.teams, &(&1.id == nav.team_id)) || 0
    {:halt, Phoenix.Component.assign(socket, :team_nav, %{nav | query: "", cursor: cursor, renaming_id: nil, editing_notes_id: nil})}
  end

  def handle_event("team_nav_search", %{"query" => query}, socket) do
    nav = socket.assigns.team_nav
    cursor = if String.trim(query) == "", do: Enum.find_index(nav.teams, &(&1.id == nav.team_id)) || 0, else: 0
    {:halt, Phoenix.Component.assign(socket, :team_nav, %{nav | query: query, cursor: cursor})}
  end

  def handle_event("team_nav_search_move", %{"dir" => dir}, socket) do
    nav = socket.assigns.team_nav
    last = max(length(search_teams(nav.teams, nav.query)) - 1, 0)
    step = if dir == "up", do: -1, else: 1
    {:halt, put_ui(socket, :cursor, nav.cursor |> Kernel.+(step) |> max(0) |> min(last))}
  end

  def handle_event("team_nav_search_pick", %{"query" => query}, socket) do
    nav = socket.assigns.team_nav

    case nav.teams |> search_teams(query) |> Enum.at(nav.cursor) do
      nil -> {:halt, socket}
      team -> {:halt, select(socket, team.id)}
    end
  end

  def handle_event("team_nav_new", params, socket) do
    result =
      case params do
        %{"template" => template_id} -> Teams.create_team_from_template(to_id(template_id))
        _ -> Teams.create_default_team()
      end

    case result do
      {:ok, id} -> {:halt, socket |> changed() |> select(id) |> put_flash(:info, "Team created.")}
      {:error, reason} -> {:halt, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  def handle_event("team_nav_new_template", %{"id" => id}, socket) do
    case TeamTemplates.create_from_team(String.to_integer(id)) do
      {:ok, _} -> {:halt, socket |> reload() |> put_flash(:info, "Template created.")}
      {:error, reason} -> {:halt, put_flash(socket, :error, "Create template failed: #{inspect(reason)}")}
    end
  end

  def handle_event("team_nav_delete_template", %{"id" => id}, socket) do
    case TeamTemplates.delete(String.to_integer(id)) do
      {:ok, _} -> {:halt, reload(socket)}
      {:error, reason} -> {:halt, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("team_nav_duplicate", %{"id" => id}, socket) do
    case Teams.duplicate_team(to_id(id)) do
      {:ok, new_id} -> {:halt, socket |> changed() |> select(new_id) |> put_flash(:info, "Team duplicated.")}
      {:error, reason} -> {:halt, put_flash(socket, :error, "Duplicate failed: #{inspect(reason)}")}
    end
  end

  def handle_event("team_nav_start_rename", %{"id" => id}, socket), do: {:halt, put_ui(socket, :renaming_id, String.to_integer(id))}

  def handle_event("team_nav_cancel_rename", _params, socket), do: {:halt, put_ui(socket, :renaming_id, nil)}

  def handle_event("team_nav_rename", %{"value" => value}, socket) do
    nav = socket.assigns.team_nav
    name = String.trim(value)
    team = Enum.find(nav.teams, &(&1.id == nav.renaming_id))
    socket = put_ui(socket, :renaming_id, nil)

    if is_nil(team) or name == "" or name == team.name do
      {:halt, socket}
    else
      case Teams.save_team(%{team | name: name}) do
        {:ok, _id} -> {:halt, changed(socket)}
        {:error, reason} -> {:halt, put_flash(socket, :error, "Rename failed: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("team_nav_start_edit_notes", %{"id" => id}, socket), do: {:halt, put_ui(socket, :editing_notes_id, String.to_integer(id))}

  def handle_event("team_nav_cancel_edit_notes", _params, socket), do: {:halt, put_ui(socket, :editing_notes_id, nil)}

  def handle_event("team_nav_edit_notes", %{"value" => value}, socket) do
    nav = socket.assigns.team_nav
    notes = String.trim(value)
    team = Enum.find(nav.teams, &(&1.id == nav.editing_notes_id))
    socket = put_ui(socket, :editing_notes_id, nil)

    if is_nil(team) or notes == String.trim(team.notes || "") do
      {:halt, socket}
    else
      {:halt, save_team(socket, %{team | notes: notes}, "Save failed")}
    end
  end

  def handle_event("team_nav_reorder", %{"ids" => ids}, socket) do
    Teams.reorder_teams(Enum.map(ids, &String.to_integer/1))
    {:halt, changed(socket)}
  end

  def handle_event("team_nav_delete", %{"id" => id}, socket) do
    id = String.to_integer(id)
    previous = socket.assigns.team_nav.team_id

    case Teams.delete_team(id) do
      {:ok, _} ->
        socket = changed(socket)
        nav = socket.assigns.team_nav

        socket =
          cond do
            socket.assigns.page != :teams or previous != id -> socket
            nav.team_id -> push_patch(socket, to: team_path(nav.team_id, plan_pane(nav.pane)))
            true -> push_patch(socket, to: ~p"/teams")
          end

        {:halt, put_flash(socket, :info, "Team deleted.")}

      {:error, reason} ->
        {:halt, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  defp build(team_id, pane, ui) do
    teams = Teams.list_teams()
    team_id = if Enum.any?(teams, &(&1.id == team_id)), do: team_id, else: first_id(teams)

    Map.merge(ui, %{
      team_id: team_id,
      pane: pane,
      teams: teams,
      templates: TeamTemplates.list(),
      profiles_by_id: Map.new(SinnerProfiles.list(), &{&1.id, &1}),
      locator_thumbs: Hooks.hook_thumbnails("locator"),
      counts: PlanCounts.for_team(team_id)
    })
  end

  defp to_id(id) when is_integer(id), do: id
  defp to_id(id), do: String.to_integer(id)

  defp first_id([%{id: id} | _]), do: id
  defp first_id([]), do: nil

  defp ui(nav), do: Map.take(nav, [:renaming_id, :editing_notes_id, :query, :cursor])

  defp put_ui(socket, key, value),
    do: Phoenix.Component.assign(socket, :team_nav, Map.put(socket.assigns.team_nav, key, value))

  def search_teams(teams, query) do
    needle = query |> String.trim() |> String.downcase()

    if needle == "" do
      teams
    else
      teams
      |> Enum.flat_map(fn team ->
        case fuzzy_score(String.downcase(team.name), needle) do
          nil -> []
          score -> [{score, team}]
        end
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
    end
  end

  defp fuzzy_score(name, needle) do
    case :binary.match(name, needle) do
      {pos, _len} -> pos
      :nomatch -> subsequence_score(String.graphemes(name), String.graphemes(needle))
    end
  end

  defp subsequence_score(name, needle) do
    positions =
      Enum.reduce_while(needle, {name, 0, []}, fn char, {rest, index, acc} ->
        case Enum.find_index(rest, &(&1 == char)) do
          nil -> {:halt, nil}
          offset -> {:cont, {Enum.drop(rest, offset + 1), index + offset + 1, [index + offset | acc]}}
        end
      end)

    case positions do
      {_rest, _index, [last | _]} -> 1000 + last
      _ -> nil
    end
  end

  defp changed(socket) do
    send(self(), :team_plans_changed)
    reload(socket)
  end

  defp select(socket, id) do
    nav = socket.assigns.team_nav
    AppSettings.put("team_nav_team", Integer.to_string(id))
    socket = Phoenix.Component.assign(socket, :team_nav, %{nav | team_id: id, counts: PlanCounts.for_team(id)})

    path = team_path(id, plan_pane(nav.pane))
    if socket.assigns.page == :teams, do: push_patch(socket, to: path), else: push_navigate(socket, to: path)
  end

  defp save_team(socket, team, error_prefix) do
    case Teams.save_team(team) do
      {:ok, _id} -> changed(socket)
      {:error, reason} -> put_flash(socket, :error, "#{error_prefix}: #{inspect(reason)}")
    end
  end

  defp stored_team_id, do: parse_id(AppSettings.get("team_nav_team"))

  defp stored_pane do
    case AppSettings.get("team_nav_pane") do
      pane when pane in @plan_panes -> pane
      _ -> "battle"
    end
  end

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_id(_value), do: nil

  def plan_pane("profiles"), do: "battle"
  def plan_pane(pane), do: pane

  def team_path(nil, pane), do: ~p"/teams?pane=#{pane}"
  def team_path(team_id, pane), do: ~p"/teams?team=#{team_id}&pane=#{pane}"

  def open_team_menu(js), do: js |> JS.push("team_nav_search_open") |> JS.focus(to: "#team-search-input")

  def profile_icons(profile_ids, profiles_by_id, locator_thumbs) do
    for id <- profile_ids, profile = profiles_by_id[id] do
      src =
        case profile do
          %{locator_hook: hook} when is_binary(hook) ->
            case locator_thumbs do
              %{^hook => version} -> ~p"/hooks/#{hook}/thumb.png?#{[v: version]}"
              _ -> SinnerProfiles.icon(profile.sinner)
            end

          _ ->
            SinnerProfiles.icon(profile.sinner)
        end

      %{name: profile.name, src: src}
    end
  end

  defp missing_label(:gift_plan), do: "gift plan"
  defp missing_label(:battle_plan), do: "battle plan"
  defp missing_label(:lineup), do: "lineup (set it up in the battle plan)"
  defp missing_label(:pack_plan), do: "pack plan"

  attr :nav, :map, required: true
  attr :on_page, :boolean, default: true

  def team_selector(assigns) do
    assigns = assign(assigns, :current, Enum.find(assigns.nav.teams, &(&1.id == assigns.nav.team_id)))

    ~H"""
    <div class="relative" phx-click-away={JS.hide(to: "#team-menu")}>
      <div class={["flex h-6 items-stretch rounded-lg border-2 bg-base-100 shadow-sm transition hover:border-primary hover:shadow-md lg:h-8", if(@on_page, do: "border-primary/60", else: "border-primary/30 grayscale opacity-70")]}>
        <button type="button" phx-click={if(@on_page, do: open_team_menu(JS.toggle(to: "#team-menu")), else: JS.push("team_nav_open"))} title={if(@on_page, do: "Switch team", else: "Open the team plans")}
                class="flex min-w-48 flex-1 items-center gap-2 rounded-md pl-3 pr-2 cursor-pointer hover:bg-primary/10 lg:min-w-60">
          <%= if @current do %>
            <span class="text-xs font-semibold lg:text-sm"><%= @current.name %></span>
            <span class="inline-flex items-center gap-1">
              <img :for={icon <- profile_icons(@current.profile_ids, @nav.profiles_by_id, @nav.locator_thumbs)} src={icon.src} title={icon.name} class="h-4 w-auto rounded object-contain" />
            </span>
            <span :if={@current.missing != []} class="badge badge-warning badge-xs" title={"Missing: " <> Enum.map_join(@current.missing, ", ", &missing_label/1)}>!</span>
          <% else %>
            <span class="text-xs text-base-content/60 lg:text-sm">Select a team</span>
          <% end %>
          <kbd class="kbd kbd-xs ml-auto hidden lg:inline-flex"><span class="[html[data-shell=tauri]_&]:hidden">T</span><span class="hidden [html[data-shell=tauri]_&]:inline">Ctrl+T</span></kbd>
          <.icon name="lucide-chevron-down" class="size-4 text-primary" />
        </button>
      </div>

      <div id="team-menu" phx-hook="TeamSearch" style="display: none" phx-window-keydown={JS.hide(to: "#team-menu")} phx-key="Escape"
           class="absolute left-0 top-full z-50 mt-1 w-[44rem] max-w-[calc(100vw-1rem)] rounded-lg border border-base-300 bg-base-100 shadow-xl">
        <div class="flex flex-col p-1.5 gap-1">
          <form phx-change="team_nav_search" autocomplete="off">
            <input type="text" id="team-search-input" name="query" value={@nav.query} placeholder="Search teams..."
                   class="input input-bordered input-sm w-full font-mono" />
          </form>
          <div id="team-list" phx-hook="SortableList" data-sort-event="team_nav_reorder" class="flex max-h-[60vh] flex-col gap-1 overflow-y-auto">
            <% results = search_teams(@nav.teams, @nav.query) %>
            <%= for {team, index} <- Enum.with_index(results) do %>
              <% selected? = @nav.team_id == team.id %>
              <div id={"team-row-#{team.id}"} data-sort-id={team.id} data-sort-handle={String.trim(@nav.query) == "" || nil} data-active={index == @nav.cursor}
                   class={"flex min-w-0 shrink-0 overflow-hidden rounded-lg border " <> if(selected?, do: "border-primary ", else: "border-base-300 ") <> if(index == @nav.cursor, do: "bg-primary/25 ring-1 ring-inset ring-primary/50", else: "bg-base-100 hover:bg-base-200")}>
                <span :if={String.trim(@nav.query) == ""} class="flex shrink-0 cursor-grab items-center pl-1 text-base-content/40" title="Drag to reorder"><.icon name="lucide-grip-vertical" class="size-4" /></span>
                <div class="flex min-w-0 flex-1 cursor-pointer items-center gap-3 p-2"
                     phx-click={JS.push("team_nav_select", value: %{id: team.id})}>
                  <%= if @nav.renaming_id == team.id do %>
                    <form phx-submit="team_nav_rename" phx-click={JS.dispatch("starlight:noop")} class="flex w-28 shrink-0">
                      <input type="text" id={"rename-team-#{team.id}"} name="value" value={team.name} phx-blur="team_nav_rename"
                             phx-keydown="team_nav_cancel_rename" phx-key="Escape" phx-hook="FocusSelect"
                             class="input input-bordered input-xs w-full font-semibold" />
                    </form>
                  <% else %>
                    <span id={"team-name-#{team.id}"} phx-hook="DblClickEvent" data-event="team_nav_start_rename" data-id={team.id}
                          title="Double-click to rename"
                          class={"w-28 shrink-0 truncate font-mono text-xs select-none " <> if(selected?, do: "font-bold", else: "")}><%= team.name %></span>
                  <% end %>
                  <span class="flex w-28 shrink-0 flex-nowrap items-center gap-1.5 overflow-hidden">
                    <img :for={icon <- profile_icons(team.profile_ids, @nav.profiles_by_id, @nav.locator_thumbs)} src={icon.src} title={icon.name} class="h-4 w-auto shrink-0 rounded object-contain" />
                    <span :if={team.missing != []} class="badge badge-warning badge-xs shrink-0" title={"Missing: " <> Enum.map_join(team.missing, ", ", &missing_label/1)}>!</span>
                  </span>
                  <%= if @nav.editing_notes_id == team.id do %>
                    <form phx-submit="team_nav_edit_notes" phx-click={JS.dispatch("starlight:noop")} class="flex min-w-0 flex-1">
                      <input type="text" id={"edit-team-notes-#{team.id}"} name="value" value={team.notes} phx-blur="team_nav_edit_notes"
                             phx-keydown="team_nav_cancel_edit_notes" phx-key="Escape" phx-hook="FocusSelect" placeholder="Notes"
                             class="input input-bordered input-xs w-full" />
                    </form>
                  <% else %>
                    <span id={"team-notes-#{team.id}"} phx-hook="DblClickEvent" data-event="team_nav_start_edit_notes" data-id={team.id}
                          title={if String.trim(team.notes || "") == "", do: "Double-click to add notes", else: team.notes}
                          class="min-h-4 min-w-0 flex-1 select-none truncate text-xs text-base-content/60"><%= team.notes %></span>
                  <% end %>
                </div>
                <div class="join shrink-0 rounded-none border-l border-base-300">
                  <button type="button" phx-click="team_nav_delete" phx-value-id={team.id}
                          data-confirm={"Delete '#{team.name}'?"} title="Delete this team"
                          class="btn btn-xs join-item h-full rounded-none border-0 text-error"><.icon name="lucide-x" class="size-3.5" /></button>
                </div>
              </div>
            <% end %>
            <div :if={@nav.teams == []} class="py-4 text-center text-sm text-base-content/40">No teams yet. Create one.</div>
            <div :if={@nav.teams != [] and results == []} class="py-4 text-center text-sm text-base-content/40">No matching team.</div>
          </div>
          <div id="new-team-menu" class="hidden flex-col gap-0.5 rounded-box border border-base-300 bg-base-100 p-1">
            <div :for={template <- @nav.templates} class="flex items-center gap-1 rounded hover:bg-base-200">
              <button type="button" phx-click={JS.push("team_nav_new", value: %{template: template.id}) |> JS.hide(to: "#new-team-menu") |> JS.hide(to: "#team-menu")}
                      title={"Create a team from the template '#{template.name}'"}
                      class="flex min-w-0 flex-1 items-center gap-1.5 px-2 py-1 text-left">
                <span class="min-w-0 truncate font-mono text-xs"><%= template.name %></span>
              </button>
              <button :if={TeamTemplates.writable?()} type="button" phx-click="team_nav_delete_template" phx-value-id={template.id}
                      data-confirm={"Delete the template '#{template.name}'?"} class="btn btn-xs btn-ghost text-error">Del</button>
            </div>
          </div>
          <div class="join w-full">
            <button type="button" phx-click={JS.push("team_nav_new") |> JS.hide(to: "#new-team-menu") |> JS.hide(to: "#team-menu")}
                    class="btn btn-primary btn-sm join-item flex-1">+ Blank Team</button>
            <button :if={@nav.templates != []} type="button" phx-click={JS.toggle(to: "#new-team-menu", display: "flex")}
                    title="Create a team from a template" class="btn btn-primary btn-sm join-item"><.icon name="lucide-chevron-down" class="size-4" /></button>
            <button :if={@current} type="button" phx-click={JS.push("team_nav_duplicate", value: %{id: @current.id}) |> JS.hide(to: "#team-menu")}
                    title="Copy the selected team, keeping its plans" class="btn btn-sm join-item flex-1">Duplicate</button>
            <button :if={@current && TeamTemplates.writable?()} type="button" phx-click="team_nav_new_template" phx-value-id={@current.id}
                    title="Add a template holding a copy of the selected team's active plans" class="btn btn-sm join-item flex-1">Templatize</button>
          </div>
        </div>
      </div>

      <button type="button" data-hotkey="team-search" phx-click={open_team_menu(JS.show(to: "#team-menu"))} class="hidden" tabindex="-1" aria-hidden="true"></button>
    </div>
    """
  end
end
