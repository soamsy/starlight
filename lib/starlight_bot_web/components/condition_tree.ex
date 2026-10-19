defmodule StarlightBotWeb.Components.ConditionTree do
  use StarlightBotWeb, :html

  alias StarlightBot.Conditions

  attr :node, :map, required: true
  attr :path, :string, required: true
  attr :values, :map, required: true
  attr :leaf, :any, required: true

  def condition_node(%{node: %{"children" => _}} = assigns) do
    ~H"""
    <div class="border border-base-300 rounded-lg p-1.5 flex flex-col gap-1">
      <div class="flex items-center gap-1">
        <button type="button" phx-click="cond_toggle_op" phx-value-path={@path} {phx_values(@values)}
                class="btn btn-2xs btn-secondary" title="Toggle AND / OR">
          <%= String.upcase(@node["op"]) %>
        </button>
        <span class="text-[10px] text-base-content/40">
          <%= if @node["op"] == "and", do: "all of", else: "any of" %>
        </span>
        <button type="button" phx-click="cond_add" phx-value-path={@path} phx-value-node="leaf" {phx_values(@values)}
                class="btn btn-2xs btn-ghost ml-auto">+ condition</button>
        <button type="button" phx-click="cond_add" phx-value-path={@path} phx-value-node="group" {phx_values(@values)}
                class="btn btn-2xs btn-ghost">+ group</button>
        <button type="button" phx-click="cond_remove" phx-value-path={@path} {phx_values(@values)}
                class="btn btn-2xs btn-ghost text-error" title="Remove group">✕</button>
      </div>
      <div class="flex flex-col gap-1 pl-3">
        <%= for {child, index} <- Enum.with_index(@node["children"]) do %>
          <.condition_node node={child} path={Conditions.child_path(@path, index)} values={@values} leaf={@leaf} />
        <% end %>
      </div>
    </div>
    """
  end

  def condition_node(assigns) do
    ~H"""
    <form phx-change="cond_update" class="flex items-center gap-1">
      <input :for={{name, value} <- @values} type="hidden" name={name} value={value} />
      <input type="hidden" name="path" value={@path} />
      <%= @leaf.(%{node: @node}) %>
      <button type="button" phx-click="cond_remove" phx-value-path={@path} {phx_values(@values)}
              class="btn btn-2xs btn-ghost text-error" title="Remove condition">✕</button>
    </form>
    """
  end

  defp phx_values(values), do: Map.new(values, fn {name, value} -> {"phx-value-#{name}", value} end)
end
