defmodule Reacher.TestProject do
  @moduledoc """
  Compiles a throwaway Mix project from generated source, loads Reacher into it,
  and runs the given assertion against the fixture module.
  """

  @reacher_modules [
    Reacher,
    Reacher.Config,
    Reacher.Context,
    Reacher.Filterer,
    Reacher.Filter.Absinthe,
    Reacher.Filter.CompilerTrace,
    Reacher.Filter.Credo,
    Reacher.Filter.Oban,
    Reacher.Filter.OTP,
    Reacher.Filter.Phoenix,
    Reacher.Filter.Project,
    Reacher.Filter.Protocol,
    Reacher.Filter.Source,
    Reacher.InjectedDelegates,
    Reacher.StaticCall,
    Reacher.Tracing.CompilerTracer,
    Reacher.Tracing.Manifest,
    Reacher.Xref,
    Mix.Tasks.Compile.Reacher,
    Mix.Tasks.Reacher
  ]
  @compile_path Mix.Project.compile_path() |> Path.expand()

  def in_project(source_builder, fun) do
    in_project(source_builder, [], fun)
  end

  def in_project(source_builder, options, fun) do
    Code.ensure_loaded!(Reacher.Filterer)

    if Keyword.get(options, :compiler_trace, false) do
      Code.ensure_loaded!(Mix.Tasks.Compile.Reacher)
      Code.ensure_loaded!(Reacher.Tracing.CompilerTracer)
      Code.ensure_loaded!(Reacher.Tracing.Manifest)
    end

    id = :erlang.unique_integer([:positive, :monotonic])
    app = String.to_atom("reacher_test_project_#{id}")
    module = Module.concat([ReacherTest, Support, "Fixture#{id}"])
    path = Path.join(System.tmp_dir!(), Atom.to_string(app))

    File.mkdir_p!(Path.join(path, "lib"))

    compiler_options =
      if Keyword.get(options, :compiler_trace, false) do
        "compilers: [:reacher] ++ Mix.compilers(),"
      else
        ""
      end

    File.write!(Path.join(path, "mix.exs"), """
    defmodule #{inspect(module)}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app},
          version: "0.1.0",
          elixir: "~> 1.18",
          #{compiler_options}
          elixirc_options: [debug_info: true, docs: true]
        ]
      end

      def application do
        [extra_applications: [:logger, :tools]]
      end
    end
    """)

    File.write!(Path.join([path, "lib", "fixture.ex"]), source_builder.(module))

    try do
      Mix.Project.in_project(app, path, fn _project ->
        ExUnit.CaptureIO.capture_io(fn -> Mix.Task.run("compile") end)
        {:ok, _} = Application.ensure_all_started(:tools)
        Code.prepend_path(@compile_path)
        Enum.each(@reacher_modules, &reload/1)

        try do
          fun.(module)
        after
          unload_fixture_modules()
        end
      end)
    after
      File.rm_rf!(path)
    end
  end

  # Fixtures stub library modules such as `Phoenix` or `Oban.Pro.Worker`.
  # Unloading them keeps one fixture's stubs from making a later fixture look
  # like it depends on that library.
  defp unload_fixture_modules do
    Mix.Project.compile_path()
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.each(fn beam ->
      module = beam |> Path.basename(".beam") |> String.to_atom()
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end)
  end

  defp reload(module) do
    :code.soft_purge(module)
    :code.delete(module)

    beam = Path.join(@compile_path, "#{module}.beam")

    {:module, ^module} =
      beam |> Path.rootname() |> String.to_charlist() |> :code.load_abs()
  end
end
