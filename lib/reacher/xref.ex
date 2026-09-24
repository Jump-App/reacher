defmodule Reacher.Xref do
  alias Reacher.StaticCall

  def with_xref_server(ebin, fun) do
    {:ok, server} = :xref.start([])

    try do
      :xref.add_directory(server, ebin, warnings: false)
      fun.(server)
    after
      :xref.stop(server)
    end
  end

  def get_modules(server) do
    {:ok, analyzed_modules} = :xref.q(server, ~c"AM")
    MapSet.new(analyzed_modules)
  end

  def unreachable(server, ebin, analyzed_modules) do
    {:ok, candidates} = :xref.q(server, ~c"X * UU")

    metadata =
      Map.new(analyzed_modules, fn module ->
        {module, read_metadata(module, ebin)}
      end)

    after_verify_targets = after_verify_targets(metadata)
    statically_resolved_calls = statically_resolved_calls(metadata)

    Enum.filter(candidates, fn {module, _name, _arity} = mfa ->
      MapSet.member?(analyzed_modules, module) and
        not macro_export?(mfa) and
        not reserved?(mfa) and
        not generated?(mfa, metadata) and
        not behaviour_callback?(mfa, metadata) and
        not MapSet.member?(after_verify_targets, mfa) and
        not MapSet.member?(statically_resolved_calls, mfa)
    end)
  end

  defp read_metadata(module, ebin) do
    beam =
      Path.join(
        ebin,
        Atom.to_string(module) <> ".beam"
      )

    with {:ok, {^module, [debug_info: debug_info]}} <-
           :beam_lib.chunks(
             String.to_charlist(beam),
             [:debug_info]
           ),
         {:debug_info_v1, :elixir_erl, data} <- debug_info,
         {:ok,
          %{
            attributes: attributes,
            definitions: definitions
          } = info} <-
           :elixir_erl.debug_info(
             :elixir_v1,
             module,
             data,
             []
           ) do
      %{
        generated: generated_definitions(definitions),
        callbacks: behaviour_callbacks(attributes),
        after_verify: Map.get(info, :after_verify, []),
        statically_resolved_calls: statically_resolved_calls(definitions)
      }
    else
      _ ->
        %{
          generated: MapSet.new(),
          callbacks: MapSet.new(),
          after_verify: [],
          statically_resolved_calls: MapSet.new()
        }
    end
  end

  defp after_verify_targets(metadata) do
    metadata
    |> Map.values()
    |> Enum.flat_map(& &1.after_verify)
    |> MapSet.new(fn {module, name} -> {module, name, 1} end)
  end

  defp statically_resolved_calls(metadata) when is_map(metadata) do
    Enum.reduce(metadata, MapSet.new(), fn {_module, module_metadata}, calls ->
      MapSet.union(calls, module_metadata.statically_resolved_calls)
    end)
  end

  defp statically_resolved_calls(definitions) when is_list(definitions) do
    Enum.reduce(definitions, MapSet.new(), fn {{_name, _arity}, _kind, _meta, clauses}, calls ->
      Enum.reduce(clauses, calls, fn {_meta, _args, _guards, body}, calls ->
        {_body, calls} =
          Macro.prewalk(body, calls, fn node, calls ->
            case StaticCall.resolve(node) do
              {:ok, call} -> {node, MapSet.put(calls, call)}
              :error -> {node, calls}
            end
          end)

        calls
      end)
    end)
  end

  defp generated_definitions(definitions) do
    definitions
    |> Enum.filter(fn
      {{_name, _arity}, kind, meta, clauses}
      when kind in [:def, :defp] ->
        macro_generated?(meta) or
          all_clauses_generated?(clauses)

      _ ->
        false
    end)
    |> Enum.map(fn
      {{name, arity}, _kind, _meta, _clauses} ->
        {name, arity}
    end)
    |> MapSet.new()
  end

  defp all_clauses_generated?([]), do: false

  defp all_clauses_generated?(clauses) do
    Enum.all?(clauses, fn
      {meta, _args, _guards, _body} ->
        macro_generated?(meta)
    end)
  end

  # A definition is treated as compiler/macro output when it is either flagged
  # `generated` (warning suppression) or carries a `:context`, which `quote`
  # stamps on every node it injects. Source parsed from a hand-written file
  # never has `:context`, so this distinguishes framework reflection functions
  # (`__components__`, `__live__`, `__struct__`, `__impl__`, ...) from real code.
  defp macro_generated?(meta) do
    meta[:generated] == true or Keyword.has_key?(meta, :context)
  end

  defp behaviour_callbacks(attributes) do
    attributes
    |> Keyword.get_values(:behaviour)
    |> Enum.flat_map(&fetch_callbacks/1)
    |> MapSet.new()
  end

  defp fetch_callbacks(behaviour) do
    case Code.Typespec.fetch_callbacks(behaviour) do
      {:ok, callbacks} ->
        Enum.map(callbacks, fn
          {{name, arity}, _specs} ->
            {name, arity}
        end)

      :error ->
        []
    end
  end

  # `__info__/1` is injected by the compiler at the Erlang level, so it never
  # appears in the Elixir definitions and cannot be caught via `:context`.
  defp reserved?({_module, :__info__, 1}), do: true
  defp reserved?(_), do: false

  defp macro_export?({_module, name, _arity}) do
    name
    |> Atom.to_string()
    |> String.starts_with?("MACRO-")
  end

  defp generated?({module, name, arity}, metadata) do
    metadata
    |> Map.fetch!(module)
    |> Map.fetch!(:generated)
    |> MapSet.member?({name, arity})
  end

  defp behaviour_callback?(
         {module, name, arity},
         metadata
       ) do
    metadata
    |> Map.fetch!(module)
    |> Map.fetch!(:callbacks)
    |> MapSet.member?({name, arity})
  end
end
