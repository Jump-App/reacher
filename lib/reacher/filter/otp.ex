defmodule Reacher.Filter.OTP do
  @moduledoc """
  Drops OTP child entry points invoked by supervisors.

  Supervisors call `child_spec/1` and the `start_link/*` function named by the
  returned child specification. Those invocations are data-driven and do not
  appear as calls in `:xref`.
  """

  @otp_behaviours [GenServer, Supervisor, DynamicSupervisor, :gen_server, :supervisor]

  @behaviour Reacher.Filterer

  @impl Reacher.Filterer
  def filter(candidates, context, _opts) do
    filter_child_entry_points(candidates, context.modules)
  end

  def filter_child_entry_points(candidates, analyzed_modules) do
    entry_points = entry_points(analyzed_modules)

    Enum.reject(candidates, &MapSet.member?(entry_points, &1))
  end

  defp entry_points(analyzed_modules) do
    Enum.reduce(analyzed_modules, MapSet.new(), fn module, entry_points ->
      functions = functions(module)

      entry_points =
        if {:child_spec, 1} in functions do
          MapSet.put(entry_points, {module, :child_spec, 1})
        else
          entry_points
        end

      if otp_child_module?(module, functions) do
        functions
        |> Enum.filter(fn {name, _arity} -> name == :start_link end)
        |> Enum.reduce(entry_points, fn {name, arity}, acc ->
          MapSet.put(acc, {module, name, arity})
        end)
      else
        entry_points
      end
    end)
  end

  defp otp_child_module?(module, functions) do
    {:child_spec, 1} in functions or
      Enum.any?(behaviours(module), &(&1 in @otp_behaviours))
  end

  defp functions(module) do
    if Code.ensure_loaded?(module), do: module.__info__(:functions), else: []
  rescue
    _error -> []
  end

  defp behaviours(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  rescue
    _error -> []
  end
end
