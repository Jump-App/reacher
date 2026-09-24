defmodule Reacher.Filter.Oban do
  @moduledoc """
  Drops Oban Pro worker metadata and hook entry points.

  Oban Pro calls generated worker metadata functions internally. Hook modules
  are reached through worker options or `Oban.Pro.Worker.attach_hook/1`, neither
  of which is represented as a call to the hook callback in `:xref`.
  """

  @oban_worker_behaviours [Oban.Worker, Oban.Pro.Worker]
  @worker_metadata_functions [__stage_opts__: 0, __stand_opts__: 0]
  @hook_callbacks [
    before_new: 2,
    before_process: 1,
    after_process: 2,
    after_process: 3,
    on_cancelled: 2,
    on_discarded: 2
  ]

  @behaviour Reacher.Filterer

  @impl Reacher.Filterer
  def filter(candidates, context, _opts) do
    filter_entry_points(candidates, context.modules, context.compile_path)
  end

  def filter_entry_points(candidates, analyzed_modules, ebin) do
    worker_modules = Enum.filter(analyzed_modules, &oban_worker?/1)

    entry_points =
      worker_entry_points(worker_modules)
      |> MapSet.union(hook_entry_points(worker_modules, analyzed_modules, ebin))

    Enum.reject(candidates, &MapSet.member?(entry_points, &1))
  end

  defp worker_entry_points(worker_modules) do
    MapSet.new(
      for module <- worker_modules,
          {name, arity} <- @worker_metadata_functions,
          function_exported?(module, name, arity) do
        {module, name, arity}
      end
    )
  end

  defp hook_entry_points(worker_modules, analyzed_modules, ebin) do
    hook_modules =
      worker_modules
      |> Enum.flat_map(&hooks_from_worker_options/1)
      |> MapSet.new()
      |> MapSet.union(attached_hooks(analyzed_modules, ebin))

    MapSet.new(
      for module <- hook_modules,
          {name, arity} <- @hook_callbacks do
        {module, name, arity}
      end
    )
  end

  defp oban_worker?(module) do
    functions = functions(module)

    Enum.any?(behaviours(module), &(&1 in @oban_worker_behaviours)) or
      ({:__opts__, 0} in functions and
         Enum.any?(@worker_metadata_functions, &(&1 in functions)))
  end

  defp hooks_from_worker_options(module) do
    if function_exported?(module, :__opts__, 0) do
      module
      |> apply(:__opts__, [])
      |> hooks_from_options()
    else
      []
    end
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp hooks_from_options(options) when is_list(options) do
    if Keyword.keyword?(options), do: normalize_hooks(Keyword.get(options, :hooks, [])), else: []
  end

  defp hooks_from_options(options) when is_map(options) do
    normalize_hooks(Map.get(options, :hooks, []))
  end

  defp hooks_from_options(_options), do: []

  defp normalize_hooks(hooks) do
    hooks
    |> List.wrap()
    |> Enum.flat_map(fn
      module when is_atom(module) -> [module]
      {module, _options} when is_atom(module) -> [module]
      _other -> []
    end)
  end

  defp attached_hooks(analyzed_modules, ebin) do
    Enum.reduce(analyzed_modules, MapSet.new(), fn module, hooks ->
      module
      |> definitions(ebin)
      |> Enum.reduce(hooks, &collect_attached_hooks/2)
    end)
  end

  defp collect_attached_hooks({{_name, _arity}, _kind, _meta, clauses}, hooks) do
    Enum.reduce(clauses, hooks, fn {_meta, _args, _guards, body}, hooks ->
      {_body, hooks} =
        Macro.prewalk(body, hooks, fn
          {{:., _, [Oban.Pro.Worker, :attach_hook]}, _, [hook | _]} = node, hooks
          when is_atom(hook) ->
            {node, MapSet.put(hooks, hook)}

          node, hooks ->
            {node, hooks}
        end)

      hooks
    end)
  end

  defp definitions(module, ebin) do
    beam = Path.join(ebin, Atom.to_string(module) <> ".beam")

    with {:ok, {^module, [debug_info: debug_info]}} <-
           :beam_lib.chunks(String.to_charlist(beam), [:debug_info]),
         {:debug_info_v1, :elixir_erl, data} <- debug_info,
         {:ok, %{definitions: definitions}} <-
           :elixir_erl.debug_info(:elixir_v1, module, data, []) do
      definitions
    else
      _error -> []
    end
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
