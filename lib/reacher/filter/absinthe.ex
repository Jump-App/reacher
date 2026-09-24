defmodule Reacher.Filter.Absinthe do
  @moduledoc """
  Drops callbacks registered through Absinthe batch helpers and router options.
  """

  @behaviour Reacher.Filterer

  @impl Reacher.Filterer
  def filter(candidates, context, _opts) do
    filter_callbacks(candidates, context.modules, context.compile_path)
  end

  def filter_callbacks(candidates, analyzed_modules, ebin) do
    callbacks =
      pipeline_callbacks(analyzed_modules)
      |> MapSet.union(batch_callbacks(analyzed_modules, ebin))

    Enum.reject(candidates, &MapSet.member?(callbacks, &1))
  end

  defp pipeline_callbacks(analyzed_modules) do
    analyzed_modules
    |> Enum.flat_map(&routes/1)
    |> Enum.flat_map(fn
      %{plug: Absinthe.Plug, plug_opts: options} when is_list(options) ->
        case Keyword.get(options, :pipeline) do
          {module, function} when is_atom(module) and is_atom(function) ->
            [{module, function, 2}]

          _other ->
            []
        end

      _route ->
        []
    end)
    |> MapSet.new()
  end

  defp routes(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__routes__, 0) do
      module.__routes__()
    else
      []
    end
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp batch_callbacks(analyzed_modules, ebin) do
    Enum.reduce(analyzed_modules, MapSet.new(), fn module, callbacks ->
      module
      |> definitions(ebin)
      |> Enum.reduce(callbacks, &collect_batch_callbacks/2)
    end)
  end

  defp collect_batch_callbacks({{_name, _arity}, _kind, _meta, clauses}, callbacks) do
    Enum.reduce(clauses, callbacks, fn {_meta, _args, _guards, body}, callbacks ->
      {_body, callbacks} =
        Macro.prewalk(body, callbacks, fn
          {{:., _, [Absinthe.Resolution.Helpers, :batch]}, _, [batcher | _]} = node, callbacks ->
            {node, add_batch_callback(callbacks, batcher)}

          node, callbacks ->
            {node, callbacks}
        end)

      callbacks
    end)
  end

  defp add_batch_callback(callbacks, {module, function})
       when is_atom(module) and is_atom(function) do
    MapSet.put(callbacks, {module, function, 2})
  end

  defp add_batch_callback(callbacks, {:{}, _, [module, function]})
       when is_atom(module) and is_atom(function) do
    MapSet.put(callbacks, {module, function, 2})
  end

  defp add_batch_callback(callbacks, {:{}, _, [module, function, _context]})
       when is_atom(module) and is_atom(function) do
    MapSet.put(callbacks, {module, function, 2})
  end

  defp add_batch_callback(callbacks, _batcher), do: callbacks

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
end
