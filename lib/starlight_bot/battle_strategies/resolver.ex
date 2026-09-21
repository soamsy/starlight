defmodule StarlightBot.BattleStrategies.Resolver do
  def type_for(data, context) when is_map(data) and context in [:mirror_dungeon, :luxcavation] do
    get_in(data, [Atom.to_string(context), "type"]) || "chain"
  end

  def type_for(_data, _context), do: "chain"
end
