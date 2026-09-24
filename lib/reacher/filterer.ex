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
    exclusions = {Reacher.Filter.Project, [exclude: Keyword.get(config, :exclude, [])]}

    Enum.reduce(builtins ++ custom ++ [exclusions], candidates, fn entry, remaining ->
      {module, opts} = if is_atom(entry), do: {entry, []}, else: entry
      module.filter(remaining, context, opts)
    end)
  end
end
