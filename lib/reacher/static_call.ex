defmodule Reacher.StaticCall do
  @moduledoc false

  def resolve({{:., _, [module_ast, function]}, _, args})
      when is_atom(function) and is_list(args) do
    with {:ok, module} <- static_module(module_ast) do
      {:ok, {module, function, length(args)}}
    end
  end

  def resolve(_ast), do: :error

  defp static_module({{:., _, [Module, :concat]}, _, [parts_ast]}) do
    with {:ok, parts} <- static_module_parts(parts_ast) do
      concat_module(parts)
    end
  end

  defp static_module({{:., _, [Module, :concat]}, _, [left, right]}) do
    with {:ok, left} <- static_module_part(left),
         {:ok, right} <- static_module_part(right) do
      concat_module([left, right])
    end
  end

  defp static_module(_module_ast), do: :error

  defp static_module_parts(parts) when is_list(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, resolved} ->
      case static_module_part(part) do
        {:ok, part} -> {:cont, {:ok, [part | resolved]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      :error -> :error
    end
  end

  defp static_module_parts({{:., _, [:erlang, :++]}, _, [left, right]}) do
    with {:ok, left} <- static_module_parts(left),
         {:ok, right} <- static_module_parts(right) do
      {:ok, left ++ right}
    end
  end

  defp static_module_parts(_parts_ast), do: :error

  defp static_module_part(part) when is_atom(part) or is_binary(part), do: {:ok, part}
  defp static_module_part(part), do: static_module(part)

  defp concat_module(parts) do
    {:ok, Module.concat(parts)}
  rescue
    _error -> :error
  end
end
