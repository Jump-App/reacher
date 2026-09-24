defmodule Reacher.Filter.Protocol do
  @moduledoc """
  Drops callbacks implemented by protocol implementation modules.

  Protocol dispatch is generated at compile time and isn't represented as a
  direct call to the implementation function in `:xref`.
  """

  @behaviour Reacher.Filterer

  @impl Reacher.Filterer
  def filter(candidates, context, _opts) do
    filter_callbacks(candidates, context.modules)
  end

  def filter_callbacks(candidates, analyzed_modules) do
    callbacks =
      analyzed_modules
      |> Enum.flat_map(&callbacks/1)
      |> MapSet.new()

    Enum.reject(candidates, &MapSet.member?(callbacks, &1))
  end

  defp callbacks(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :__impl__, 1),
         protocol when is_atom(protocol) <- module.__impl__(:protocol),
         true <- Code.ensure_loaded?(protocol),
         true <- function_exported?(protocol, :__protocol__, 1) do
      for {name, arity} <- protocol.__protocol__(:functions) do
        {module, name, arity}
      end
    else
      _other -> []
    end
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end
end
