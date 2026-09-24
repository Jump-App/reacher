defmodule Reacher.Config do
  @moduledoc false

  def load(path) do
    case File.read(path) do
      {:ok, source} ->
        {config, _bindings} = Code.eval_string(source, [], file: path)
        validate!(config, path)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read Reacher configuration", path: path
    end
  end

  defp validate!(config, path) do
    unless Keyword.keyword?(config), do: invalid!(path, "expected a keyword list")

    for key <- Keyword.keys(config), key not in [:filterers, :exclude] do
      invalid!(path, "unknown option #{inspect(key)}")
    end

    filterers = Keyword.get(config, :filterers, [])
    unless is_list(filterers), do: invalid!(path, ":filterers must be a list")
    Enum.each(filterers, &validate_filterer!(&1, path))

    exclusions = Keyword.get(config, :exclude, [])

    unless is_list(exclusions) and Enum.all?(exclusions, &exclusion?/1) do
      invalid!(
        path,
        ":exclude must contain modules, {function, arity}, or {module, function, arity}"
      )
    end

    config
  end

  defp validate_filterer!(module, path) when is_atom(module),
    do: validate_filterer!({module, []}, path)

  defp validate_filterer!({module, opts}, path) when is_atom(module) do
    unless Keyword.keyword?(opts),
      do: invalid!(path, "options for #{inspect(module)} must be a keyword list")

    unless Code.ensure_loaded?(module) and function_exported?(module, :filter, 3) do
      invalid!(path, "filterer #{inspect(module)} must be loadable and export filter/3")
    end
  end

  defp validate_filterer!(entry, path),
    do:
      invalid!(path, "invalid filterer #{inspect(entry)}; expected a module or {module, options}")

  defp exclusion?(module) when is_atom(module), do: true
  defp exclusion?({name, arity}), do: is_atom(name) and is_integer(arity) and arity >= 0
  defp exclusion?({module, name, arity}), do: is_atom(module) and exclusion?({name, arity})
  defp exclusion?(_entry), do: false

  defp invalid!(path, message),
    do: raise(ArgumentError, "Invalid Reacher configuration in #{path}: #{message}")
end
