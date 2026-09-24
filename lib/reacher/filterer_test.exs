defmodule Reacher.FiltererTest do
  use ExUnit.Case, async: false

  import Reacher.TestProject, only: [in_project: 2]

  test "project filterers extend defaults, receive context and options, and run in order" do
    in_project(
      fn module ->
        """
        defmodule #{inspect(module)} do
          def child_spec(_opts), do: %{}
          def dynamically_called, do: :ok
          def excluded, do: :ok
          def unused, do: :ok
        end

        defmodule #{inspect(module)}.Filterer do
          @behaviour Reacher.Filterer

          @impl Reacher.Filterer
          def filter(candidates, context, opts) do
            send(Process.get(:filterer_test_pid), {:filter, candidates, context, opts})
            Enum.reject(candidates, fn {_, name, _} -> name == opts[:name] end)
          end
        end
        """
      end,
      fn module ->
        Process.put(:filterer_test_pid, self())
        filterer = Module.concat(module, Filterer)

        File.write!(Path.join(File.cwd!(), ".reacher.exs"), """
        send(Process.get(:filterer_test_pid), :config_loaded)
        [filterers: [{#{inspect(filterer)}, [name: :dynamically_called]}, #{inspect(filterer)}],
         exclude: [{#{inspect(module)}, :excluded, 0}]]
        """)

        results = Reacher.analyze()
        assert {module, :unused, 0} in results
        refute {module, :dynamically_called, 0} in results
        refute {module, :excluded, 0} in results
        refute {module, :child_spec, 1} in results
        refute {filterer, :filter, 3} in results

        assert_received :config_loaded
        refute_received :config_loaded
        assert_received {:filter, first, context, [name: :dynamically_called]}
        assert_received {:filter, second, ^context, []}
        assert {module, :dynamically_called, 0} in first
        refute {module, :dynamically_called, 0} in second
        assert {module, :excluded, 0} in second
        refute {module, :child_spec, 1} in first
        assert module in context.modules
        assert context.project_root == File.cwd!()
        assert context.compile_path == Path.expand(Mix.Project.compile_path())
        assert context.compiler_traced_sources == MapSet.new()
        assert context.compiler_references == MapSet.new()
      end
    )
  end
end
