defmodule Reacher.InjectedDelegates do
  @moduledoc """
  Finds `defdelegate` definitions that a macro injected into a module.

  `Kernel.defdelegate/2` builds the function head as `[line: __ENV__.line]`, so
  a delegate written inside `quote` loses the `:context` that marks other
  macro-injected definitions. Such a delegate takes the line of the macro call
  (`use`, a macro, or `defmodule` for `@before_compile`), while a delegate
  written in the module's source sits on a line with a literal `defdelegate`
  call. Delegates whose line has no such call are injected.
  """

  @doc """
  Returns the `{name, arity}` of the injected delegates among a module's
  `definitions`, along with `cache` updated with the parsed `source`.

  `cache` maps source paths to the lines holding a literal `defdelegate` call,
  so a file defining several modules is parsed once.
  """
  def detect(beam, source, definitions, cache) do
    with [_ | _] = candidates <- candidates(definitions),
         {:ok, delegates} <- delegates(beam),
         [_ | _] = candidates <- Enum.filter(candidates, &MapSet.member?(delegates, elem(&1, 0))) do
      {result, cache} = literal_lines(source, cache)
      {injected(candidates, result), cache}
    else
      _none -> {MapSet.new(), cache}
    end
  end

  # Only `defdelegate` builds a head without `:column`. The docs entry alone is
  # not enough: a `def` overriding a delegate after `defoverridable` keeps the
  # delegate's `:delegate_to`.
  defp candidates(definitions) do
    for {{name, arity}, :def, meta, _clauses} <- definitions,
        not Keyword.has_key?(meta, :context),
        meta[:generated] != true,
        not Keyword.has_key?(meta, :column),
        is_integer(meta[:line]),
        do: {{name, arity}, meta[:line]}
  end

  defp delegates(beam) do
    case :beam_lib.chunks(String.to_charlist(beam), [~c"Docs"]) do
      {:ok, {_module, [{~c"Docs", binary}]}} ->
        {:docs_v1, _anno, _language, _format, _moduledoc, _metadata, entries} =
          :erlang.binary_to_term(binary)

        delegates =
          for {{:function, name, arity}, _anno, _signature, _doc, %{delegate_to: _}} <- entries,
              into: MapSet.new(),
              do: {name, arity}

        {:ok, delegates}

      _error ->
        :error
    end
  end

  defp injected(candidates, {:ok, lines}) do
    for {function, line} <- candidates,
        not MapSet.member?(lines, line),
        into: MapSet.new(),
        do: function
  end

  defp injected(_candidates, :error), do: MapSet.new()

  defp literal_lines(source, cache) do
    case Map.fetch(cache, source) do
      {:ok, result} ->
        {result, cache}

      :error ->
        result = parse_literal_lines(source)
        {result, Map.put(cache, source, result)}
    end
  end

  defp parse_literal_lines(source) do
    with {:ok, contents} <- File.read(source),
         {:ok, ast} <- Code.string_to_quoted(contents, file: source) do
      {_ast, lines} = Macro.prewalk(ast, MapSet.new(), &collect_line/2)
      {:ok, lines}
    else
      _error -> :error
    end
  end

  defp collect_line({:defdelegate, meta, [_, _]} = node, lines),
    do: {node, MapSet.put(lines, meta[:line])}

  defp collect_line(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :defdelegate]}, meta, [_, _]} = node,
         lines
       ),
       do: {node, MapSet.put(lines, meta[:line])}

  defp collect_line(node, lines), do: {node, lines}
end
