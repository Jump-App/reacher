defmodule Reacher do
  def analyze do
    %{unreachable: unreachable} = do_analyze()
    unreachable
  end

  def analyze(module) do
    analyze()
    |> Enum.filter(fn {mod, _, _} -> mod == module end)
    |> print()
  end

  @doc """
  Like `analyze/0` but also returns unnecessary skips.
  """
  def analyze_full do
    do_analyze()
  end

  defp print(unreachable) do
    unreachable
    |> Enum.sort()
    |> Enum.each(fn {module, name, arity} ->
      Mix.shell().info("#{inspect(module)}.#{name}/#{arity}")
    end)
  end

  defp do_analyze do
    project_root = File.cwd!()
    config = Reacher.Config.load(Path.join(project_root, ".reacher.exs"))
    compile_path = Path.expand(Mix.Project.compile_path())
    ebin = String.to_charlist(compile_path)

    Reacher.Xref.with_xref_server(ebin, fn server ->
      modules = Reacher.Xref.get_modules(server)

      context = %Reacher.Context{
        modules: modules,
        compile_path: compile_path,
        project_root: project_root,
        compiler_traced_sources: Reacher.Tracing.Manifest.traced_sources(),
        compiler_references: Reacher.Tracing.Manifest.references()
      }

      {unreachable, unnecessary_skips} =
        Reacher.Xref.unreachable(server, ebin, modules)
        |> Reacher.Filterer.run(context, config)

      %{unreachable: unreachable, unnecessary_skips: unnecessary_skips}
    end)
  end
end
