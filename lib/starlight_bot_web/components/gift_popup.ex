defmodule StarlightBotWeb.Components.GiftPopup do
  use Phoenix.Component
  alias StarlightBotWeb.Live.GiftPlanEditorLive, as: Gifts

  attr :popup, :map, default: nil
  attr :gifts_by_name, :map, required: true
  attr :gifts_by_id, :map, required: true
  attr :theme_packs_by_gift_id, :map, required: true

  def gift_popup(assigns) do
    assigns = assign(assigns, :gift, assigns.popup && assigns.gifts_by_name[assigns.popup.name])

    ~H"""
    <div id="gift-popup" phx-hook="GiftPopup" class="contents" data-gift={@gift && @gift.name} data-x={@popup && @popup.x} data-y={@popup && @popup.y}>
      <div :if={@gift} data-popup-control class="fixed z-50 w-max max-w-sm max-h-[calc(100vh-1rem)] overflow-y-auto rounded-lg border border-base-300 bg-base-100 p-2 shadow-[0_10px_30px_rgba(0,0,0,0.6),0_2px_8px_rgba(0,0,0,0.4)] flex flex-col gap-1">
        <div class="flex items-center gap-2">
          <img src={@gift.image_path} class="w-8 h-8 rounded object-cover shrink-0" />
          <div class="flex flex-col min-w-0">
            <span class="text-xs font-semibold"><%= @gift.name %></span>
            <span class="text-[10px] text-base-content/60">T<%= @gift.tier %><%= if @gift.affinity not in [nil, "none"], do: " · #{@gift.affinity}" %></span>
          </div>
          <div :if={Gifts.uptie_view_available?(@gift, "uptie2", @gifts_by_id)} class="join ml-auto self-start">
            <% current = Enum.find_index(Gifts.uptie_views(), &(&1 == @popup.view)) %>
            <button :for={{level, index} <- Enum.with_index(Gifts.uptie_views()) |> Enum.drop(1)} type="button" data-popup-control
                    phx-click="set_gift_popup_view" phx-value-level={if index == current, do: "base", else: level}
                    disabled={not Gifts.uptie_view_available?(@gift, level, @gifts_by_id)}
                    class={"btn btn-xs join-item " <> if(index <= current, do: "btn-secondary", else: "btn-outline")}>
              <%= Gifts.uptie_view_icon(level) %>
            </button>
          </div>
        </div>
        <p class="text-[11px] whitespace-pre-line"><%= Gifts.gift_detail_text(@gift, @popup.view, @gifts_by_id) %></p>
        <% ingredients = Gifts.fusion_ingredients(@gift, @gifts_by_id, @theme_packs_by_gift_id) %>
        <div :if={ingredients} class="border-t border-base-300 pt-1 flex flex-col gap-0.5">
          <span class="text-[10px] uppercase tracking-wide text-base-content/50">Other</span>
          <div :for={ingredient <- ingredients} class="flex items-center gap-1.5 text-[11px]">
            <img :if={ingredient.image_path} src={ingredient.image_path} class="w-4 h-4 rounded object-cover shrink-0" />
            <span :if={!ingredient.image_path} class="w-4 shrink-0"></span>
            <span><%= ingredient.name %></span>
            <span :if={ingredient.packs != []} class="ml-auto pl-3 text-[10px] text-base-content/50"><%= Enum.join(ingredient.packs, ", ") %></span>
          </div>
        </div>
        <p :if={@theme_packs_by_gift_id[@gift.id]} class="text-[10px] text-base-content/60">
          Theme pack: <%= Enum.join(@theme_packs_by_gift_id[@gift.id], ", ") %>
        </p>
        <p :if={Map.get(@gift, :extreme_only)} class="text-[10px] text-error">Extreme only</p>
        <p :if={Map.get(@gift, :hard_only) && !Map.get(@gift, :extreme_only)} class="text-[10px] text-warning">Hard only</p>
      </div>
    </div>
    """
  end
end
