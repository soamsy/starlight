defmodule StarlightBotWeb.Components.GiftRefreshPanel do
  use Phoenix.Component
  import StarlightBotWeb.Components.Icon, only: [icon: 1]
  import StarlightBotWeb.Components.ConditionTree, only: [condition_node: 1]
  alias StarlightBotWeb.Live.GiftPlanEditorLive, as: Gifts
  alias StarlightBot.GiftPlans

  attr :section, :any, required: true
  attr :plan_data, :any, required: true
  attr :refresh_tabs, :any, required: true
  attr :refresh_paths, :any, required: true
  attr :editing_condition_case_id, :any, required: true
  def refresh_panel(assigns) do
    ~H"""
    <% section = @section %>
    <% refresh_from = Gifts.active_refresh_from(@refresh_tabs, section) %>
    <% refresh_scheduled = section["refresh_scheduled"] == true %>
    <div class="flex flex-col mt-4 rounded-xl bg-base-300 p-2">
      <div class="flex items-center gap-2 pb-1">
        <span class="flex items-center gap-1 text-sm font-semibold"><.icon name="lucide-refresh-cw" class="size-4" />Refresh</span>
        <span class="text-xs text-base-content/60">Applies to every stage</span>
        <button phx-click="list_add_refresh_case" class="btn btn-xs btn-outline">+ Case</button>
        <Gifts.refresh_costs section={section} from={refresh_from} path={Gifts.refresh_path(assigns, section, refresh_from)} plan_data={@plan_data} />
        <button :if={not refresh_scheduled} type="button" phx-click="list_refresh_add_schedule" class="btn btn-ghost btn-xs ml-auto">Add Schedule</button>
      </div>
      <Gifts.refresh_tabs :if={refresh_scheduled} section={section} from={refresh_from} />
      <div class={"flex flex-col gap-1 " <> if(refresh_scheduled, do: "p-1 border-2 border-primary rounded-b-lg rounded-tr-lg", else: "")}>
        <div id={"refresh-cases-#{section["id"]}-#{refresh_from}"} phx-hook="SortableList" data-sort-event="list_reorder_refresh" data-sort-scope={section["id"]}
             class="flex flex-col gap-1">
          <div :for={{refresh_case, index} <- Enum.with_index(GiftPlans.refresh_cases(section, refresh_from))} data-sort-id={refresh_case["id"]}
               class="rounded border border-base-300 bg-base-200 px-1 py-1 flex items-start gap-2">
            <span data-sort-handle class="cursor-grab text-base-content/40 select-none px-1 leading-6">⠿</span>
            <span class="text-[11px] font-semibold text-base-content/70 w-12 shrink-0 leading-6"><%= if index == 0, do: "if", else: "else if" %></span>
            <div class="flex-1 min-w-64">
              <%= if refresh_case["condition"] do %>
                <%= if @editing_condition_case_id == refresh_case["id"] do %>
                  <div phx-click-away="close_case_condition" class="flex items-start gap-1">
                    <button type="button" phx-click="close_case_condition" title="Close the condition editor" class="btn btn-ghost btn-xs h-6 min-h-6 px-1">▾</button>
                    <div class="flex-1 min-w-0">
                      <.condition_node node={refresh_case["condition"]} path="" values={%{"case_id" => refresh_case["id"]}} removable={false}
                                       leaf={&Gifts.gift_leaf(Map.merge(&1, %{plan_data: @plan_data, section: section}))} />
                    </div>
                  </div>
                <% else %>
                  <button type="button" phx-click="open_case_condition" phx-value-case_id={refresh_case["id"]}
                          class="btn btn-outline btn-xs bg-base-100 h-6 min-h-6 w-full justify-start font-normal normal-case">
                    <span class="text-base-content/50">▸</span><span class="truncate"><%= GiftPlans.condition_label(refresh_case["condition"], @plan_data) || "always" %></span>
                  </button>
                <% end %>
              <% else %>
                <div class="flex items-center gap-2 h-6">
                  <span class="text-[11px] text-base-content/60">always</span>
                  <button type="button" phx-click="cond_add" phx-value-case_id={refresh_case["id"]} phx-value-path="" phx-value-node="leaf"
                          class="btn btn-ghost btn-xs">+ Condition</button>
                </div>
              <% end %>
              <p :for={warning <- GiftPlans.condition_warnings(refresh_case["condition"], @plan_data, section)} class="mt-1 flex items-center gap-1 text-[11px] text-warning">
                <.icon name="lucide-triangle-exclamation-point" class="size-3.5 shrink-0" /><%= warning %>
              </p>
            </div>
            <span class="text-[11px] font-semibold text-base-content/70 leading-6">then</span>
            <form phx-change="list_update_refresh_case" class="flex items-center gap-1 shrink-0">
              <input type="hidden" name="case_id" value={refresh_case["id"]} />
              <div class="join">
                <label :for={{action, label} <- [{"leave", "Leave"}, {"refresh", "Refresh"}, {"affinity_refresh", "Keyword"}]}
                       class="join-item btn btn-xs gap-1 has-[:checked]:btn-primary">
                  <input type="radio" name="action" value={action} checked={refresh_case["action"] == action} class="hidden" />
                  <%= label %><.icon :if={action == "affinity_refresh"} name="lucide-refresh-cw" class="size-3" />
                </label>
                <details id={"refresh-aff-#{refresh_case["id"]}"} phx-hook="FloatingDropdown" data-close-on-click class="dropdown join-item border-0">
                  <summary class={"btn btn-xs rounded-[inherit] gap-1 flex-nowrap whitespace-nowrap " <> if(refresh_case["action"] == "affinity_refresh", do: "btn-primary", else: "opacity-40 grayscale")}>
                    <img :if={(refresh_case["affinity"] || @plan_data["affinity"]) not in [nil, ""]} src={Gifts.gift_affinity_icon(refresh_case["affinity"] || @plan_data["affinity"])} class="sinner-icon w-3 h-3 object-contain shrink-0" />
                    <%= refresh_case["affinity"] || "plan" %>
                  </summary>
                  <div popover="manual" class="dropdown-content z-30 w-max rounded-box border border-base-300 bg-base-100 p-1 shadow">
                    <ul class="menu menu-xs w-36 p-0 whitespace-nowrap">
                      <li>
                        <label class="cursor-pointer">
                          <input type="radio" name="affinity" value="" checked={refresh_case["affinity"] == nil} class="hidden" />
                          <img :if={@plan_data["affinity"] not in [nil, ""]} src={Gifts.gift_affinity_icon(@plan_data["affinity"])} class="w-3 h-3 object-contain" />plan
                        </label>
                      </li>
                      <li class="pointer-events-none my-1 h-px bg-base-300 p-0"></li>
                      <%= for affinity <- Gifts.affinity_order() do %>
                        <li :if={affinity == "slash"} class="pointer-events-none my-1 h-px bg-base-300 p-0"></li>
                        <li>
                          <label class="cursor-pointer">
                            <input type="radio" name="affinity" value={affinity} checked={refresh_case["affinity"] == affinity} class="hidden" />
                            <img src={Gifts.gift_affinity_icon(affinity)} class="w-3 h-3 object-contain" /><%= affinity %>
                          </label>
                        </li>
                      <% end %>
                    </ul>
                  </div>
                </details>
              </div>
              <span :if={refresh_case["action"] != "leave"} class="text-[11px] font-semibold text-base-content/70">up to</span>
              <input :if={refresh_case["action"] != "leave"} type="number" name="max" min="0" value={refresh_case["max"]} placeholder="∞"
                     phx-debounce="300" class="input input-bordered input-xs w-14" />
              <span :if={refresh_case["action"] != "leave"} class="text-[11px] font-semibold text-base-content/70 whitespace-nowrap">cost after &gt;=</span>
              <input :if={refresh_case["action"] != "leave"} type="number" name="min_cost" min="0" value={Map.get(refresh_case, "min_cost", GiftPlans.default_min_cost())}
                     phx-debounce="300" class="input input-bordered input-xs w-16" />
            </form>
            <button type="button" phx-click="list_remove_refresh_case" phx-value-case_id={refresh_case["id"]} class="btn btn-ghost btn-xs px-1 text-error"><.icon name="lucide-x" class="size-3.5" /></button>
          </div>
        </div>
        <div class="rounded border border-dashed border-base-300 px-1 py-1 flex items-center gap-2">
          <span class="px-1 invisible">⠿</span>
          <span class="text-[11px] font-semibold text-base-content/70 w-12 shrink-0"><%= if GiftPlans.refresh_cases(section, refresh_from) == [], do: "always", else: "else" %></span>
          <span class="text-[11px] text-base-content/60">leave the shop</span>
        </div>
      </div>
    </div>
    """
  end
end
