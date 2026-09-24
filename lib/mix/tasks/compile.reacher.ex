defmodule Mix.Tasks.Compile.Reacher do
  use Mix.Task.Compiler

  @moduledoc false
  @recursive true

  @impl Mix.Task.Compiler
  def run(_args) do
    Reacher.Tracing.CompilerTracer.start()
    tracers = Code.get_compiler_option(:tracers)

    Mix.Task.Compiler.after_compiler(
      :elixir,
      &after_elixir_compiler(&1, tracers)
    )

    Code.put_compiler_option(:tracers, [Reacher.Tracing.CompilerTracer | tracers])

    :noop
  end

  @impl Mix.Task.Compiler
  def manifests do
    [Reacher.Tracing.Manifest.manifest_path()]
  end

  @impl Mix.Task.Compiler
  def clean do
    Enum.each(manifests(), &File.rm/1)
  end

  defp after_elixir_compiler({status, _diagnostics} = result, tracers) do
    Code.put_compiler_option(:tracers, tracers)

    if status == :ok do
      Reacher.Tracing.CompilerTracer.snapshot()
      |> Reacher.Tracing.Manifest.persist()
    end

    Reacher.Tracing.CompilerTracer.stop()
    result
  end
end
