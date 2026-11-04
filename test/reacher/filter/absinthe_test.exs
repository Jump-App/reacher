defmodule Reacher.Filter.AbsintheTest do
  use ExUnit.Case, async: false

  import Reacher.TestProject, only: [in_project: 2]

  test "does not report registered batch and pipeline callbacks" do
    in_project(
      fn module ->
        callbacks = Module.concat(module, Callbacks)
        registration = Module.concat(module, Registration)
        pipeline = Module.concat(module, Pipeline)
        router = Module.concat(module, Router)
        unrelated = Module.concat(module, Unrelated)

        """
        defmodule Absinthe.Plug do
        end

        defmodule Absinthe.Resolution.Helpers do
          def batch(_batcher, _item, _callback), do: :ok
        end

        defmodule #{inspect(callbacks)} do
          def load(_context, items), do: items
        end

        defmodule #{inspect(registration)} do
          import Absinthe.Resolution.Helpers

          def resolve(item) do
            batch({#{inspect(callbacks)}, :load, :context}, item, fn result -> result end)
          end
        end

        defmodule #{inspect(pipeline)} do
          def for_document(config, options), do: {config, options}
        end

        defmodule #{inspect(router)} do
          def __routes__ do
            [%{plug: Absinthe.Plug, plug_opts: [pipeline: {#{inspect(pipeline)}, :for_document}]}]
          end
        end

        defmodule #{inspect(unrelated)} do
          def load(_context, items), do: items
          def for_document(config, options), do: {config, options}
        end
        """
      end,
      fn module ->
        callbacks = Module.concat(module, Callbacks)
        pipeline = Module.concat(module, Pipeline)
        unrelated = Module.concat(module, Unrelated)
        unreachable = Reacher.analyze() |> MapSet.new()

        refute MapSet.member?(unreachable, {callbacks, :load, 2})
        refute MapSet.member?(unreachable, {pipeline, :for_document, 2})
        assert MapSet.member?(unreachable, {unrelated, :load, 2})
        assert MapSet.member?(unreachable, {unrelated, :for_document, 2})
      end
    )
  end

  test "reports batch and pipeline callbacks when the project does not depend on Absinthe" do
    in_project(
      fn module ->
        callbacks = Module.concat(module, Callbacks)
        registration = Module.concat(module, Registration)
        pipeline = Module.concat(module, Pipeline)
        router = Module.concat(module, Router)

        """
        defmodule #{inspect(callbacks)} do
          def load(_context, items), do: items
        end

        defmodule #{inspect(registration)} do
          @compile {:no_warn_undefined, Absinthe.Resolution.Helpers}

          def resolve(item) do
            Absinthe.Resolution.Helpers.batch({#{inspect(callbacks)}, :load}, item, & &1)
          end
        end

        defmodule #{inspect(pipeline)} do
          def for_document(config, options), do: {config, options}
        end

        defmodule #{inspect(router)} do
          def __routes__ do
            [%{plug: Absinthe.Plug, plug_opts: [pipeline: {#{inspect(pipeline)}, :for_document}]}]
          end
        end
        """
      end,
      fn module ->
        callbacks = Module.concat(module, Callbacks)
        pipeline = Module.concat(module, Pipeline)
        unreachable = Reacher.analyze() |> MapSet.new()

        assert MapSet.member?(unreachable, {callbacks, :load, 2})
        assert MapSet.member?(unreachable, {pipeline, :for_document, 2})
      end
    )
  end
end
