defmodule Reacher.Filter.Project do
  @moduledoc "Applies explicit project suppressions after entry-point discovery."
  @behaviour Reacher.Filterer

  @impl Reacher.Filterer
  def filter(candidates, _context, opts) do
    exclusions = opts |> Keyword.get(:exclude, []) |> MapSet.new()

    Enum.reject(candidates, fn {module, name, arity} = mfa ->
      MapSet.member?(exclusions, mfa) or
        MapSet.member?(exclusions, {name, arity}) or
        MapSet.member?(exclusions, module)
    end)
  end

  def filter_excluded(candidates, config_path \\ ".reacher.exs") do
    filter(candidates, nil, Reacher.Config.load(config_path))
  end
end
