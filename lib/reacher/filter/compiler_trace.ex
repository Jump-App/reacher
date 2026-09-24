defmodule Reacher.Filter.CompilerTrace do
  @moduledoc """
  Drops calls confirmed by the compiler-trace manifest.
  """

  alias Reacher.Tracing.Manifest

  @behaviour Reacher.Filterer

  @impl Reacher.Filterer
  def filter(candidates, context, _opts) do
    reject_references(candidates, context.compiler_references)
  end

  def filter_compile_time_calls(candidates) do
    reject_references(candidates, Manifest.references())
  end

  defp reject_references(candidates, references) do
    Enum.reject(candidates, fn {module, name, arity} ->
      MapSet.member?(references, {to_string(module), to_string(name), arity})
    end)
  end
end
