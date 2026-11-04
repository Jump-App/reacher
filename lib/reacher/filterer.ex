defmodule Reacher.Filterer do
  @moduledoc """
  Removes recognized entry points or explicit suppressions from an analysis.

  Implementations receive the remaining candidates, shared analysis context,
  and their configured options. They must return a subset of the candidates.
  """

  @callback filter([mfa()], Reacher.Context.t(), keyword()) :: [mfa()]

  @doc "Built-in filterers, in execution order."
  def defaults do
    [
      Reacher.Filter.OTP,
      Reacher.Filter.Oban,
      Reacher.Filter.Protocol,
      Reacher.Filter.Absinthe,
      Reacher.Filter.Phoenix,
      Reacher.Filter.CompilerTrace,
      Reacher.Filter.Source,
      Reacher.Filter.Credo
    ]
  end

  @doc false
  def run(candidates, context, config) do
    builtins = defaults()
    custom = Keyword.get(config, :filterers, [])
    exclude_opts = [exclude: Keyword.get(config, :exclude, [])]

    filtered_candidates =
      Enum.reduce(builtins ++ custom, candidates, fn entry, remaining ->
        {module, opts} = if is_atom(entry), do: {entry, []}, else: entry
        module.filter(remaining, context, opts)
      end)

    unused = reject_used_groups(filtered_candidates, context.groups)

    unnecessary_skips = Reacher.Filter.Project.unnecessary_skips(unused, exclude_opts)

    filtered =
      unused
      |> Reacher.Filter.Project.filter(context, exclude_opts)
      |> reject_used_groups(context.groups)
      |> collapse_default_families(context.default_families)

    {filtered, unnecessary_skips}
  end

  # Filterers and exclusions see every member of a group (a call cycle, which
  # includes every arity of a default-argument family), so a use or exclusion
  # of any member keeps the whole group out of the report.
  defp reject_used_groups(candidates, []), do: candidates

  defp reject_used_groups(candidates, groups) do
    remaining = MapSet.new(candidates)
    group_by_member = for group <- groups, member <- group, into: %{}, do: {member, group}

    Enum.filter(candidates, fn mfa ->
      case Map.fetch(group_by_member, mfa) do
        {:ok, group} -> Enum.all?(group, &MapSet.member?(remaining, &1))
        :error -> true
      end
    end)
  end

  defp collapse_default_families(candidates, families) when map_size(families) == 0,
    do: candidates

  defp collapse_default_families(candidates, families) do
    family_by_member =
      for {full, members} <- families, member <- members, into: %{}, do: {member, full}

    candidates
    |> Enum.map(&Map.get(family_by_member, &1, &1))
    |> Enum.uniq()
  end
end
