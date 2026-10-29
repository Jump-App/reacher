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
  Returns unused candidates and the default-argument families among them.

  A function with default arguments compiles to the full-arity definition plus
  one stub per omitted default, and each stub calls the full arity locally, so
  `:xref` never sees the full arity as unused. Such a family is treated as one
  unit: it is unused when no member has a caller outside the family, in which
  case every member is returned as a candidate and the family is listed in the
  returned map, keyed by its full-arity MFA.
  """
  def unreachable(server, ebin, analyzed_modules) do
    {:ok, unused} = :xref.q(server, ~c"X * UU")

    metadata =
      Map.new(analyzed_modules, fn module ->
        {module, read_metadata(module, ebin)}
      end)

    families = default_families(metadata)
    family_members = families |> Map.values() |> List.flatten() |> MapSet.new()
    unused_families = unused_default_families(server, families)

    after_verify_targets = after_verify_targets(metadata)
    statically_resolved_calls = statically_resolved_calls(metadata)

    candidates =
      unused
      |> Enum.reject(&MapSet.member?(family_members, &1))
      |> Enum.concat(unused_families |> Map.values() |> List.flatten())
      |> Enum.reject(fn {module, _name, _arity} = mfa ->
        not MapSet.member?(analyzed_modules, module) or
          macro_export?(mfa) or
          reserved?(mfa) or
          generated?(mfa, metadata) or
          behaviour_callback?(mfa, metadata) or
          MapSet.member?(after_verify_targets, mfa) or
          MapSet.member?(statically_resolved_calls, mfa)
      end)

    {candidates, unused_families}
  end

  defp default_families(metadata) do
    for {module, %{default_families: families}} <- metadata,
        {name, arity, defaults} <- families,
        into: %{} do
      members = Enum.map((arity - defaults)..arity, &{module, name, &1})
      {{module, name, arity}, members}
    end
  end

  defp unused_default_families(_server, families) when map_size(families) == 0, do: %{}

  defp unused_default_families(server, families) do
    family_by_member =
      for {full, members} <- families, member <- members, into: %{}, do: {member, full}

    targets = family_by_member |> Map.keys() |> Enum.map_join(", ", &xref_function/1)
    {:ok, edges} = :xref.q(server, String.to_charlist("E || [#{targets}]"))

    used =
      for {caller, callee} <- edges,
          family = Map.fetch!(family_by_member, callee),
          Map.get(family_by_member, caller) != family,
          into: MapSet.new(),
          do: family

    Map.reject(families, fn {full, _members} -> MapSet.member?(used, full) end)
  end

  defp xref_function({module, name, arity}) do
    ~c"~tw:~tw/~b" |> :io_lib.format([module, name, arity]) |> IO.chardata_to_string()
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
