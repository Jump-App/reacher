defmodule Reacher.Filter.Credo do
  @moduledoc """
  Drops functions that are only referenced from `.credo.exs`.

  Credo's config is evaluated, not compiled, so `:xref` never sees the calls it
  makes into custom-check config modules (e.g.
  `MyApp.CredoChecks.UnsafeConfig.preloads/0`) nor the `{Module, :fun}`
  callback tuples it hands to checks (e.g. `valid_name_callback:
  {MyApp.CredoChecks.Example, :valid_name?}`). Without this pass, each of
  those helpers looks unreachable.
  """

  @config_path ".credo.exs"

  @behaviour Reacher.Filterer

  @impl Reacher.Filterer
  def filter(candidates, context, _opts) do
    filter_config_references(candidates, Path.join(context.project_root, ".credo.exs"))
  end

  def filter_config_references(candidates, config_path \\ @config_path) do
    {calls, callbacks} = referenced_from_config(config_path)

    candidates
    |> Enum.reject(fn {module, name, _arity} = mfa ->
      MapSet.member?(calls, mfa) or MapSet.member?(callbacks, {module, name})
    end)
  end

  defp referenced_from_config(path) do
    case File.read(path) do
      {:ok, source} ->
        source
        |> Code.string_to_quoted!()
        |> collect_references()

      {:error, _} ->
        {MapSet.new(), MapSet.new()}
    end
  end

  defp collect_references(ast) do
    {_ast, refs} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, collect_node(node) ++ acc}
      end)

    {calls, callbacks} = Enum.split_with(refs, &match?({:call, _}, &1))

    {
      MapSet.new(calls, fn {:call, mfa} -> mfa end),
      MapSet.new(callbacks, fn {:callback, mf} -> mf end)
    }
  end

  # Remote call: `Module.function(args)`.
  defp collect_node({{:., _, [{:__aliases__, _, parts}, name]}, _, args})
       when is_atom(name) and is_list(args) do
    with_module(parts, fn module -> [{:call, {module, name, length(args)}}] end)
  end

  # Callback tuple: `{Module, :function}`. Credo decides the arity when it
  # invokes the callback, so we can only match on the name.
  defp collect_node({{:__aliases__, _, parts}, name}) when is_atom(name) do
    with_module(parts, fn module -> [{:callback, {module, name}}] end)
  end

  defp collect_node(_node), do: []

  defp with_module(parts, fun) do
    if Enum.all?(parts, &is_atom/1) do
      fun.(Module.concat(parts))
    else
      []
    end
  end
end
