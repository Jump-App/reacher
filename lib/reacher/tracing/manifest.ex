defmodule Reacher.Tracing.Manifest do
  @moduledoc """
  Persists calls resolved by the Elixir compiler while compiling module bodies.
  """

  @manifest_version 1
  @manifest "reacher_compile_calls"

  def references do
    manifest()
    |> Map.values()
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  def referenced?(mfa) do
    MapSet.member?(references(), call_key(mfa))
  end

  def traced_sources do
    manifest()
    |> Map.keys()
    |> MapSet.new()
  end

  def persist(compiled_sources) when is_map(compiled_sources) do
    previous_sources = manifest()

    sources =
      previous_sources
      |> Map.merge(normalize_sources(compiled_sources))
      |> Map.reject(fn {source, _calls} -> not File.regular?(source) end)

    if sources == previous_sources do
      :ok
    else
      write_manifest(sources)
    end
  end

  def manifest_path do
    Path.join(Mix.Project.manifest_path(), @manifest)
  end

  defp manifest do
    with {:ok, binary} <- File.read(manifest_path()),
         %{version: @manifest_version, sources: sources} <-
           :erlang.binary_to_term(binary, [:safe]),
         true <- is_map(sources) do
      normalize_sources(sources)
    else
      _error -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  defp normalize_sources(sources) do
    Map.new(sources, fn {source, calls} ->
      {Path.expand(source), MapSet.new(calls, &call_key/1)}
    end)
  end

  defp call_key({module, name, arity}) do
    {to_string(module), to_string(name), arity}
  end

  defp write_manifest(sources) do
    path = manifest_path()
    temporary_path = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.mkdir_p!(Path.dirname(path))

    contents =
      :erlang.term_to_binary(%{
        version: @manifest_version,
        sources: Map.new(sources, fn {source, calls} -> {source, MapSet.to_list(calls)} end)
      })

    File.write!(temporary_path, contents)
    File.rename!(temporary_path, path)
    :ok
  end
end
