defmodule Reacher.Filter.Source do
  @moduledoc """
  Finds source-only registrations and calls outside the compiled environment.

  Files without traces use literal-call discovery. Traced files retain source
  discovery for environment conditionals and case-template setup code.

  Source is parsed only. Reacher never evaluates or compiles it.
  """

  @behaviour Reacher.Filterer

  @impl Reacher.Filterer
  def filter(candidates, context, _opts) do
    filter_compile_time_calls(candidates, context.compiler_traced_sources)
  end

  def filter_compile_time_calls(candidates, compiler_traced_sources \\ MapSet.new()) do
    references = references(compiler_traced_sources)
    Enum.reject(candidates, &MapSet.member?(references, &1))
  end

  def references(compiler_traced_sources \\ MapSet.new()) do
    Mix.Project.config()
    |> Keyword.get(:elixirc_paths, ["lib"])
    |> Enum.flat_map(&source_files/1)
    |> Enum.reduce(MapSet.new(), fn path, references ->
      collect_compile_time_calls? =
        not MapSet.member?(compiler_traced_sources, Path.expand(path))

      references_in_file(path, references, collect_compile_time_calls?)
    end)
  end

  defp source_files(path) do
    path
    |> Path.expand(File.cwd!())
    |> Path.join("**/*.ex")
    |> Path.wildcard()
  end

  defp references_in_file(path, references, collect_compile_time_calls?) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source) do
      collect_modules(ast, nil, references, collect_compile_time_calls?)
    else
      _error -> references
    end
  end

  defp collect_modules(
         {:defmodule, _, [module_ast, [do: body]]},
         parent,
         references,
         collect_compile_time_calls?
       ) do
    case resolve_module_definition(module_ast, parent) do
      {:ok, module} ->
        body_without_nested_modules = strip_nested_modules(body)
        aliases = collect_aliases(body_without_nested_modules, module)

        references =
          collect_calls(
            body_without_nested_modules,
            aliases,
            module,
            references,
            collect_compile_time_calls?
          )

        collect_nested_modules(body, module, references, collect_compile_time_calls?)

      :error ->
        collect_nested_modules(body, parent, references, collect_compile_time_calls?)
    end
  end

  defp collect_modules(ast, parent, references, collect_compile_time_calls?) do
    collect_nested_modules(ast, parent, references, collect_compile_time_calls?)
  end

  defp collect_nested_modules(ast, parent, references, collect_compile_time_calls?) do
    case ast do
      {:defmodule, _, [_module_ast, [do: _body]]} = node ->
        collect_modules(node, parent, references, collect_compile_time_calls?)

      term when is_list(term) ->
        Enum.reduce(term, references, fn node, references ->
          collect_nested_modules(node, parent, references, collect_compile_time_calls?)
        end)

      term when is_tuple(term) ->
        term
        |> Tuple.to_list()
        |> Enum.reduce(references, fn node, references ->
          collect_nested_modules(node, parent, references, collect_compile_time_calls?)
        end)

      _term ->
        references
    end
  end

  defp strip_nested_modules(ast) do
    Macro.prewalk(ast, fn
      {:defmodule, _, [_module_ast, [do: _body]]} -> nil
      node -> node
    end)
  end

  defp collect_aliases(ast, current_module) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [module_ast, options]} = node, aliases when is_list(options) ->
          {node, put_alias(aliases, module_ast, options, current_module)}

        {:alias, _, [module_ast]} = node, aliases ->
          {node, put_alias(aliases, module_ast, [], current_module)}

        node, aliases ->
          {node, aliases}
      end)

    aliases
  end

  defp put_alias(aliases, module_ast, options, current_module) do
    with {:ok, module} <- resolve_module(module_ast, aliases, current_module),
         {:ok, alias_name} <- alias_name(module, options, aliases, current_module) do
      Map.put(aliases, alias_name, module)
    else
      _error -> aliases
    end
  end

  defp alias_name(module, options, aliases, current_module) do
    case Keyword.fetch(options, :as) do
      {:ok, alias_ast} ->
        with {:ok, alias_module} <- resolve_module(alias_ast, aliases, current_module) do
          {:ok, alias_module |> Module.split() |> List.last() |> String.to_atom()}
        end

      :error ->
        {:ok, module |> Module.split() |> List.last() |> String.to_atom()}
    end
  end

  defp collect_calls(
         ast,
         aliases,
         current_module,
         references,
         collect_compile_time_calls?
       ) do
    ast = expand_pipes(ast)

    {_ast, references} =
      Macro.prewalk(ast, references, fn
        {kind, _, [condition | _]} = node, references
        when not collect_compile_time_calls? and kind in [:if, :unless, :case] ->
          references =
            if environment_condition?(condition) do
              collect_calls(node, aliases, current_module, references, true)
            else
              references
            end

          {node, references}

        {:using, _, _args} = node, references when not collect_compile_time_calls? ->
          references =
            if exports?(current_module, :"MACRO-__using__", 2) do
              collect_calls(node, aliases, current_module, references, true)
            else
              references
            end

          {node, references}

        {{:., _, [module_ast, function]}, _, args} = node, references
        when collect_compile_time_calls? and is_atom(function) and is_list(args) ->
          reference =
            with {:ok, module} <- resolve_module(module_ast, aliases, current_module) do
              {module, function, length(args)}
            end

          {node, put_reference(references, reference)}

        {:on_mount, _, [module_ast]} = node, references ->
          reference =
            with {:ok, module} <- resolve_module(module_ast, aliases, current_module),
                 true <- exports?(module, :on_mount, 4) do
              {module, :on_mount, 4}
            else
              _other -> :error
            end

          {node, put_reference(references, reference)}

        {route, _, arguments} = node, references
        when route in [:get, :post, :put, :patch, :delete, :options, :head, :match] and
               is_list(arguments) ->
          {node, put_route_references(references, arguments, aliases, current_module)}

        {:use, _, [module_ast, variant | _rest]} = node, references when is_atom(variant) ->
          if collect_compile_time_calls? do
            reference =
              with {:ok, module} <- resolve_module(module_ast, aliases, current_module),
                   true <- exports_use_variant?(module, variant) do
                {module, variant, 0}
              else
                _other -> :error
              end

            {node, put_reference(references, reference)}
          else
            {node, references}
          end

        node, references ->
          {node, references}
      end)

    references
  end

  defp environment_condition?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Mix]}, :env]}, _, []} = node, _found? ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp expand_pipes(ast) do
    Macro.prewalk(ast, fn
      {:|>, _, [left, right]} -> Macro.pipe(left, right, 0)
      node -> node
    end)
  end

  defp put_route_references(references, arguments, aliases, current_module) do
    if exports?(current_module, :__routes__, 0) do
      case route_target(arguments) do
        {module_ast, action} ->
          case resolve_route_module(module_ast, aliases, current_module, action) do
            {:ok, module} ->
              references
              |> MapSet.put({module, action, 2})
              |> put_html_entry_point(module, action)

            _error ->
              references
          end

        nil ->
          references
      end
    else
      references
    end
  end

  defp route_target(arguments) do
    case Enum.reverse(arguments) do
      [options, action, module_ast | _rest] when is_list(options) and is_atom(action) ->
        {module_ast, action}

      [action, module_ast | _rest] when is_atom(action) ->
        {module_ast, action}

      _other ->
        nil
    end
  end

  defp resolve_route_module(module_ast, aliases, current_module, action) do
    with {:ok, module} <- resolve_module(module_ast, aliases, current_module),
         true <- exports?(module, action, 2) do
      {:ok, module}
    else
      _other -> resolve_route_module_in_namespace(module_ast, current_module, action)
    end
  end

  defp resolve_route_module_in_namespace({:__aliases__, _, parts}, current_module, action)
       when is_atom(current_module) do
    namespace = current_module |> Module.split() |> Enum.drop(-1)

    with {:ok, module} <- concat_module(namespace ++ Enum.map(parts, &Atom.to_string/1)),
         true <- exports?(module, action, 2) do
      {:ok, module}
    else
      _other -> :error
    end
  end

  defp resolve_route_module_in_namespace(_module_ast, _current_module, _action), do: :error

  defp put_html_entry_point(references, controller, action) do
    case html_module(controller) do
      {:ok, html} ->
        if exports?(html, action, 1),
          do: MapSet.put(references, {html, action, 1}),
          else: references

      :error ->
        references
    end
  end

  defp html_module(controller) do
    parts = Module.split(controller)

    case List.pop_at(parts, -1) do
      {name, namespace} ->
        if String.ends_with?(name, "Controller") do
          concat_module(namespace ++ [String.replace_suffix(name, "Controller", "HTML")])
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp put_reference(references, {_module, _function, _arity} = reference) do
    MapSet.put(references, reference)
  end

  defp put_reference(references, _error), do: references

  defp exports_use_variant?(module, variant) do
    exports?(module, :"MACRO-__using__", 2) and exports?(module, variant, 0)
  end

  defp exports?(module, function, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp exports?(_module, _function, _arity), do: false

  defp resolve_module_definition({:__aliases__, _, [{:__MODULE__, _, _} | rest]}, parent)
       when is_atom(parent) and not is_nil(parent) do
    concat_module([parent | rest])
  end

  defp resolve_module_definition({:__aliases__, _, [Elixir | _]} = module_ast, _parent) do
    resolve_module(module_ast, %{}, nil)
  end

  defp resolve_module_definition({:__aliases__, _, parts}, parent)
       when is_atom(parent) and not is_nil(parent) do
    concat_module([parent | parts])
  end

  defp resolve_module_definition(module_ast, parent) do
    resolve_module(module_ast, %{}, parent)
  end

  defp resolve_module(module, _aliases, _current_module) when is_atom(module), do: {:ok, module}

  defp resolve_module({:__MODULE__, _, _context}, _aliases, current_module)
       when is_atom(current_module),
       do: {:ok, current_module}

  defp resolve_module({:__aliases__, _, [first | rest]}, aliases, current_module) do
    case Map.fetch(aliases, first) do
      {:ok, module} -> concat_module([module | rest])
      :error -> resolve_unaliased_module([first | rest], current_module)
    end
  end

  defp resolve_module(_module_ast, _aliases, _current_module), do: :error

  defp resolve_unaliased_module(parts, _current_module), do: concat_module(parts)

  defp concat_module(parts) do
    {:ok, Module.concat(parts)}
  rescue
    _error -> :error
  end
end
