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

  @doc """
  Returns exclusion entries that do not match any candidate.
  """
  def unnecessary_skips(candidates, opts) do
    exclusions = Keyword.get(opts, :exclude, [])
    candidate_set = MapSet.new(candidates)
    modules = MapSet.new(candidates, fn {m, _, _} -> m end)
    name_arities = MapSet.new(candidates, fn {_, n, a} -> {n, a} end)

    Enum.reject(exclusions, fn
      {m, n, a} when is_atom(m) and is_atom(n) and is_integer(a) ->
        MapSet.member?(candidate_set, {m, n, a})

      {n, a} when is_atom(n) and is_integer(a) ->
        MapSet.member?(name_arities, {n, a})

      module when is_atom(module) ->
        MapSet.member?(modules, module)
    end)
  end

  def filter_excluded(candidates, config_path \\ ".reacher.exs") do
    filter(candidates, nil, Reacher.Config.load(config_path))
  end
end
