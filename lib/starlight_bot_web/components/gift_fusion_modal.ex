defmodule StarlightBotWeb.Components.GiftFusionModal do
  use Phoenix.Component
  alias StarlightBotWeb.Live.GiftPlanEditorLive, as: Gifts
  alias StarlightBot.GiftPlans
  alias StarlightBot.GiftPlans.Routes

  attr :section, :any, required: true
  attr :plan_data, :any, required: true
  attr :fusion_entry_id, :any, required: true
  attr :gifts_by_name, :any, required: true
  attr :gifts_by_id, :any, required: true
  attr :route_clipboard, :any, required: true
  attr :route_templates, :any, required: true
  attr :route_shop, :any, required: true
  def fusion_modal(assigns) do
    ~H"""
    <% section = @section %>
    <% fusion_section = @fusion_entry_id && Enum.find(GiftPlans.sections(@plan_data, section["id"]), &GiftPlans.find_entry(&1, @fusion_entry_id)) %>
    <% fusion_entry = fusion_section && GiftPlans.find_entry(fusion_section, @fusion_entry_id) %>
    <% target = fusion_entry && @gifts_by_name[GiftPlans.subject_gift(fusion_entry)] %>
    <div :if={fusion_entry && target && fusion_entry["fusion"]} class="modal modal-open">
      <div class="modal-box w-11/12 max-w-4xl h-[85vh] flex flex-col gap-2">
        <div class="flex items-center gap-2">
          <img src={target.image_path} class="w-10 h-10 rounded object-cover" />
          <div class="flex flex-col">
            <span class="text-sm font-semibold"><%= target.name %></span>
            <span class="text-[11px] text-base-content/60">Tier <%= target.tier %> · <%= target.affinity %> · <%= fusion_entry["fusion"]["type"] %> fusion</span>
          </div>
          <button phx-click="list_close_fusion" class="btn btn-sm btn-ghost ml-auto">Close</button>
        </div>
        <%= if GiftPlans.fixed_fusion?(fusion_entry) do %>
          <span class="text-[11px] text-base-content/60">
            Fixed recipe. Each ingredient is its own entry in this stage: a missing one is bought if its entry has Buy on,
            otherwise fused if its entry has Fuse on. Red ingredients aren't in this stage, so they're never bought or fused for this.
          </span>
          <Gifts.recipe_tree gift={target} section={fusion_section} gifts_by_id={@gifts_by_id} gifts_by_name={@gifts_by_name} />
        <% else %>
          <span class="text-[11px] text-base-content/60">
            Routes, tried in order. Each picks a combo from the valid pool and can buy missing ingredients up to a tier,
            demand leftover unkept items before fusing, and fuse sub-goals for its ingredient tiers.
            Normal shops skip combos marked super only. These routes are shared by every floor of this entry.
          </span>
          <div class="flex items-center gap-2">
            <button type="button" phx-click="rt_copy" phx-value-def_id={fusion_entry["id"]} class="btn btn-xs">Copy routes</button>
            <button type="button" phx-click="rt_paste" phx-value-def_id={fusion_entry["id"]} class="btn btn-xs"
                    disabled={is_nil(@route_clipboard) or @route_clipboard.tier != target.tier}
                    data-confirm="Replace all routes with the copied ones?">Paste routes</button>
            <span :if={@route_clipboard} class="text-[11px] text-base-content/60">
              Clipboard: <%= @route_clipboard.name %> (T<%= @route_clipboard.tier %>, <%= length(@route_clipboard.routes) %> route(s))
            </span>
          </div>
          <div class="flex flex-col gap-1">
            <span class="text-[11px] text-base-content/60">T<%= target.tier %> templates</span>
            <span :if={@route_templates[target.tier] == []} class="text-[11px] text-base-content/60">No T<%= target.tier %> templates yet</span>
            <div :for={template <- @route_templates[target.tier] || []} class="flex items-center gap-2">
              <button type="button" phx-click="rt_apply_template" phx-value-def_id={fusion_entry["id"]} phx-value-ref={template.ref} class="btn btn-xs"
                      data-confirm={"Replace all routes with the template #{template.name}?"}>Apply</button>
              <span class="text-xs font-semibold"><%= template.name %></span>
              <span class="text-[11px] text-base-content/60"><%= Enum.map_join(template.routes, ", ", &Routes.label/1) %></span>
              <button :if={template.deletable} type="button" phx-click="rt_delete_template" phx-value-ref={template.ref} class="btn btn-xs btn-ghost"
                      data-confirm={"Delete the template #{template.name}?"}>Delete</button>
            </div>
            <form phx-submit="rt_save_template" class="flex items-center gap-2">
              <input type="hidden" name="def_id" value={fusion_entry["id"]} />
              <input type="text" name="name" placeholder="Template name" autocomplete="off" class="input input-xs input-bordered" />
              <button type="submit" class="btn btn-xs">Save routes as T<%= target.tier %> template</button>
            </form>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-[11px] text-base-content/60">Routes for</span>
            <div class="join">
              <button :for={shop <- [:normal, :super]} type="button" phx-click="set_route_shop" phx-value-shop={shop}
                      class={"btn btn-xs join-item " <> if(@route_shop == shop, do: "btn-primary", else: "btn-outline")}>
                <%= if shop == :normal, do: "Normal shop", else: "Super shop" %>
              </button>
            </div>
          </div>
          <Gifts.route_list def_id={fusion_entry["id"]} routes={fusion_entry["fusion"]["routes"] || []} tier={target.tier} shop={@route_shop} />
        <% end %>
      </div>
      <div class="modal-backdrop" phx-click="list_close_fusion"></div>
    </div>
    """
  end
end
