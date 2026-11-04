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

  @doc """
  Returns unused candidates, the default-argument families among them, and the
  groups of candidates that are reported together or not at all.

  A function is unused when nothing outside its own call cycle calls it, so
  recursion (direct, through `__MODULE__`, or mutual) does not count as a use.
  The exported functions of one cycle form a group: when any of them is an
  entry point, the whole group is used.

  A function with default arguments compiles to the full-arity definition plus
  one stub per omitted default, and each stub calls the full arity locally, so
  such a family is treated as one unit: it is unused when no member has a
  caller outside the family (or its cycle), in which case every member is
  returned as a candidate, belongs to the same group, and the family is listed
  in the returned map, keyed by its full-arity MFA.
  """
  def unreachable(server, ebin, analyzed_modules) do
    metadata =
      Map.new(analyzed_modules, fn module ->
        {module, read_metadata(module, ebin)}
      end)

    families = default_families(metadata)
    {dead_components, unused_families} = dead_components(server, families)

    after_verify_targets = after_verify_targets(metadata)
    statically_resolved_calls = statically_resolved_calls(metadata)

    entry_point? = fn mfa ->
      macro_export?(mfa) or
        reserved?(mfa) or
        generated?(mfa, metadata) or
        behaviour_callback?(mfa, metadata) or
        MapSet.member?(after_verify_targets, mfa) or
        MapSet.member?(statically_resolved_calls, mfa)
    end

    groups =
      dead_components
      |> Enum.map(fn component ->
        Enum.filter(component, fn {module, _name, _arity} ->
          MapSet.member?(analyzed_modules, module)
        end)
      end)
      |> Enum.reject(&(&1 == [] or Enum.any?(&1, entry_point?)))

    {List.flatten(groups), unused_families, Enum.filter(groups, &match?([_, _ | _], &1))}
  end

  defp default_families(metadata) do
    for {module, %{default_families: families}} <- metadata,
        {name, arity, defaults} <- families,
        into: %{} do
      members = Enum.map((arity - defaults)..arity, &{module, name, &1})
      {{module, name, arity}, members}
    end
  end

  # Builds the call graph with each default-argument family collapsed into its
  # full-arity MFA, then condenses it into strongly connected components. A
  # component without incoming edges has no caller outside itself, so its
  # exported functions are unused unless one of them is an entry point.
  defp dead_components(server, families) do
    {:ok, functions} = :xref.q(server, ~c"F")
    {:ok, exported} = :xref.q(server, ~c"X")
    {:ok, edges} = :xref.q(server, ~c"E || F")

    family_by_member =
      for {full, members} <- families, member <- members, into: %{}, do: {member, full}

    node = &Map.get(family_by_member, &1, &1)

    dead_components =
      with_call_graph(functions, edges, node, fn graph ->
        condensation = :digraph_utils.condensation(graph)

        try do
          for component <- :digraph.vertices(condensation),
              :digraph.in_degree(condensation, component) == 0,
              do: component
        after
          :digraph.delete(condensation)
        end
      end)

    exported = MapSet.new(exported)

    components =
      dead_components
      |> Enum.map(fn component ->
        component
        |> Enum.flat_map(&Map.get(families, &1, [&1]))
        |> Enum.filter(&MapSet.member?(exported, &1))
      end)
      |> Enum.reject(&(&1 == []))

    {components, Map.take(families, List.flatten(dead_components))}
  end

  defp with_call_graph(functions, edges, node, fun) do
    graph = :digraph.new()

    try do
      Enum.each(functions, &:digraph.add_vertex(graph, node.(&1)))

      for {caller, callee} <- edges,
          caller = node.(caller),
          callee = node.(callee),
          caller != callee do
        :digraph.add_vertex(graph, caller)
        :digraph.add_edge(graph, caller, callee)
      end

      fun.(graph)
    after
      :digraph.delete(graph)
    end
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
      generated = generated_definitions(definitions)
      default_families = default_families_in(definitions, generated)

      %{
        generated: MapSet.difference(generated, default_stubs(default_families)),
        default_families: default_families,
        callbacks: behaviour_callbacks(attributes),
        after_verify: Map.get(info, :after_verify, []),
        statically_resolved_calls: statically_resolved_calls(definitions)
      }
    else
      _ ->
        %{
          generated: MapSet.new(),
          default_families: [],
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

  # The compiler stamps `:defaults` on the full-arity definition and emits the
  # stubs with an `:elixir_def` context, which `generated_definitions/1` would
  # otherwise treat as macro output.
  defp default_families_in(definitions, generated) do
    for {{name, arity}, :def, meta, _clauses} <- definitions,
        defaults = meta[:defaults],
        is_integer(defaults),
        not MapSet.member?(generated, {name, arity}),
        do: {name, arity, defaults}
  end

  defp default_stubs(default_families) do
    for {name, arity, defaults} <- default_families,
        stub_arity <- (arity - defaults)..(arity - 1)//1,
        into: MapSet.new(),
        do: {name, stub_arity}
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
