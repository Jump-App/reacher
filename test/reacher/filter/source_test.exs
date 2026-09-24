defmodule Reacher.Filter.SourceTest do
  use ExUnit.Case, async: false

  import Reacher.TestProject, only: [in_project: 2, in_project: 3]

  test "does not report calls evaluated while compiling module attributes" do
    in_project(
      fn module ->
        metadata = Module.concat(module, Metadata)
        consumer = Module.concat(module, Consumer)
        unrelated = Module.concat(module, Unrelated)

        """
        defmodule #{inspect(metadata)} do
          def options, do: [:compiled]
        end

        defmodule #{inspect(consumer)} do
          alias #{inspect(metadata)}, as: Metadata

          @options Metadata.options()
          def options, do: @options
        end

        defmodule #{inspect(unrelated)} do
          def options, do: [:unused]
        end
        """
      end,
      fn module ->
        metadata = Module.concat(module, Metadata)
        unrelated = Module.concat(module, Unrelated)
        unreachable = Reacher.analyze() |> MapSet.new()

        refute MapSet.member?(unreachable, {metadata, :options, 0})
        assert MapSet.member?(unreachable, {unrelated, :options, 0})
      end
    )
  end

  test "resolves nested module definitions relative to their parent" do
    in_project(
      fn module ->
        error_controller = Module.concat(module, ErrorController)

        """
        defmodule #{inspect(module)}.DSL do
          defmacro get(_path, _controller, _action), do: nil
        end

        defmodule #{inspect(error_controller)} do
          def not_found(conn, _params), do: conn
        end

        defmodule #{inspect(module)} do
          defmodule Router do
            import #{inspect(module)}.DSL
            def __routes__, do: []

            if false do
              get "/*path", #{inspect(error_controller)}, :not_found
            end
          end
        end
        """
      end,
      [compiler_trace: true],
      fn module ->
        error_controller = Module.concat(module, ErrorController)
        unreachable = Reacher.analyze() |> MapSet.new()

        refute MapSet.member?(unreachable, {error_controller, :not_found, 2})
      end
    )
  end

  test "counts the piped value when resolving call arity" do
    in_project(
      fn module ->
        target = Module.concat(module, Target)
        consumer = Module.concat(module, Consumer)

        """
        defmodule #{inspect(target)} do
          def emit(value), do: {value, :default}
          def emit(value, option), do: {value, option}
        end

        defmodule #{inspect(consumer)} do
          def emit(value), do: value |> #{inspect(target)}.emit(:custom)
        end
        """
      end,
      fn module ->
        target = Module.concat(module, Target)
        unreachable = Reacher.analyze() |> MapSet.new()

        assert MapSet.member?(unreachable, {target, :emit, 1})
        refute MapSet.member?(unreachable, {target, :emit, 2})
      end
    )
  end

  test "finds Phoenix callbacks in source-only DSL registrations" do
    in_project(
      fn module ->
        hook = Module.concat(module, Hook)
        error_controller = Module.concat(module, ErrorController)
        router = Module.concat(module, Router)

        """
        defmodule #{inspect(module)}.DSL do
          defmacro on_mount(_module), do: nil
          defmacro get(_path, _controller, _action), do: nil
        end

        defmodule #{inspect(hook)} do
          def on_mount(_name, _params, _session, socket), do: {:cont, socket}
        end

        defmodule #{inspect(error_controller)} do
          def not_found(conn, _params), do: conn
        end

        defmodule #{inspect(router)} do
          import #{inspect(module)}.DSL
          def __routes__, do: []

          on_mount #{inspect(hook)}

          if false do
            get "/*path", ErrorController, :not_found
          end
        end
        """
      end,
      [compiler_trace: true],
      fn module ->
        hook = Module.concat(module, Hook)
        error_controller = Module.concat(module, ErrorController)
        unreachable = Reacher.analyze() |> MapSet.new()

        refute MapSet.member?(unreachable, {hook, :on_mount, 4})
        refute MapSet.member?(unreachable, {error_controller, :not_found, 2})
      end
    )
  end
end
