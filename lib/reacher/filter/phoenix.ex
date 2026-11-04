defmodule Reacher.Filter.Phoenix do
  @moduledoc """
  Drops Phoenix callbacks exposed through router, endpoint, LiveView, and
  rendering metadata.
  """

  @behaviour Reacher.Filterer

  @impl Reacher.Filterer
  def filter(candidates, context, _opts) do
    filter_entry_points(candidates, context.modules)
  end

  def filter_entry_points(candidates, analyzed_modules) do
    entry_points = entry_points(analyzed_modules)

    candidates
    |> Enum.reject(&MapSet.member?(entry_points, &1))
  end

  defp entry_points(analyzed_modules) do
    MapSet.new(phoenix_entry_points(analyzed_modules) ++ form_data_entry_points(analyzed_modules))
  end

  defp phoenix_entry_points(analyzed_modules) do
    if Code.ensure_loaded?(Phoenix) do
      router_entry_points =
        analyzed_modules
        |> Enum.filter(&router_module?/1)
        |> Enum.flat_map(&routes/1)
        |> Enum.flat_map(&route_entry_points/1)

      router_entry_points ++ Enum.flat_map(analyzed_modules, &endpoint_entry_points/1)
    else
      []
    end
  end

  defp form_data_entry_points(analyzed_modules) do
    if Code.ensure_loaded?(Phoenix.HTML.FormData) do
      Enum.flat_map(analyzed_modules, &form_data_entry_point/1)
    else
      []
    end
  end

  defp route_entry_points(%{plug: plug, plug_opts: action} = route)
       when is_atom(action) and not is_nil(action) do
    [{plug, action, 2} | html_entry_points(plug, action)] ++
      metadata_entry_points(Map.get(route, :metadata))
  end

  defp route_entry_points(%{plug: plug, plug_opts: options} = route) when is_list(options) do
    [{plug, :init, 1}, {plug, :call, 2} | metadata_entry_points(Map.get(route, :metadata))]
  end

  defp route_entry_points(route) when is_map(route) do
    metadata_entry_points(Map.get(route, :metadata))
  end

  defp route_entry_points(_route), do: []

  defp metadata_entry_points(metadata) do
    collect_metadata(metadata, [])
  end

  defp collect_metadata(function, entry_points) when is_function(function) do
    info = Function.info(function)

    case {Keyword.get(info, :module), Keyword.get(info, :name), Keyword.get(info, :arity)} do
      {module, name, arity} when is_atom(module) and is_atom(name) and is_integer(arity) ->
        [{module, name, arity} | entry_points]

      _other ->
        entry_points
    end
  end

  defp collect_metadata({module, function, arguments}, entry_points)
       when is_atom(module) and is_atom(function) and is_list(arguments) do
    [{module, function, length(arguments) + 1} | entry_points]
  end

  defp collect_metadata(term, entry_points) when is_map(term) do
    Enum.reduce(term, entry_points, fn {key, value}, entry_points ->
      entry_points = collect_metadata(key, entry_points)
      collect_metadata(value, entry_points)
    end)
  end

  defp collect_metadata(term, entry_points) when is_list(term) do
    Enum.reduce(term, entry_points, fn value, entry_points ->
      collect_metadata(value, entry_points)
    end)
  end

  defp collect_metadata(term, entry_points) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> collect_metadata(entry_points)
  end

  defp collect_metadata(_term, entry_points), do: entry_points

  defp endpoint_entry_points(module) do
    socket_entry_points(module) ++ render_error_entry_points(module)
  end

  defp html_entry_points(controller, action) do
    with {:ok, html} <- html_module(controller),
         true <- Code.ensure_loaded?(html),
         true <- function_exported?(html, action, 1) do
      [{html, action, 1}]
    else
      _other -> []
    end
  end

  defp html_module(controller) when is_atom(controller) do
    parts = Module.split(controller)

    case List.pop_at(parts, -1) do
      {name, namespace} ->
        if String.ends_with?(name, "Controller") do
          {:ok, Module.concat(namespace ++ [String.replace_suffix(name, "Controller", "HTML")])}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp html_module(_controller), do: :error

  defp form_data_entry_point(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :__impl__, 1),
         Phoenix.HTML.FormData <- module.__impl__(:protocol),
         true <- function_exported?(module, :input_type, 3) do
      [{module, :input_type, 3}]
    else
      _other -> []
    end
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp socket_entry_points(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__sockets__, 0) do
      module
      |> apply(:__sockets__, [])
      |> collect_named_mfas(:check_origin, [])
    else
      []
    end
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp collect_named_mfas({key, {module, function, arguments}}, key, entry_points)
       when is_atom(module) and is_atom(function) and is_list(arguments) do
    [{module, function, length(arguments) + 1} | entry_points]
  end

  defp collect_named_mfas(term, key, entry_points) when is_map(term) do
    Enum.reduce(term, entry_points, fn value, entry_points ->
      collect_named_mfas(value, key, entry_points)
    end)
  end

  defp collect_named_mfas(term, key, entry_points) when is_list(term) do
    Enum.reduce(term, entry_points, fn value, entry_points ->
      collect_named_mfas(value, key, entry_points)
    end)
  end

  defp collect_named_mfas(term, key, entry_points) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> collect_named_mfas(key, entry_points)
  end

  defp collect_named_mfas(_term, _key, entry_points), do: entry_points

  defp render_error_entry_points(module) do
    module
    |> render_errors_config()
    |> Keyword.get(:formats, [])
    |> Enum.flat_map(fn
      {_format, renderer} when is_atom(renderer) -> [{renderer, :render, 2}]
      _other -> []
    end)
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp render_errors_config(module) do
    application_config =
      case Application.get_application(module) do
        application when is_atom(application) ->
          application
          |> Application.get_env(module, [])
          |> Keyword.get(:render_errors)

        _other ->
          nil
      end

    cond do
      is_list(application_config) -> application_config
      function_exported?(module, :config, 1) -> apply(module, :config, [:render_errors]) || []
      true -> []
    end
  end

  defp router_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__routes__, 0)
  end

  defp routes(module) do
    module.__routes__()
  rescue
    _ -> []
  end
end
