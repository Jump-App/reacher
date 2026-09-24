defmodule Reacher.Filter.CredoTest do
  use ExUnit.Case, async: false

  import Reacher.TestProject, only: [in_project: 2]

  test "does not report functions referenced from .credo.exs" do
    in_project(
      fn module ->
        """
        defmodule #{inspect(module)} do
          def called_directly, do: :ok
          def used_as_callback(_a, _b, _c), do: :ok
          def unused, do: :unused
        end
        """
      end,
      fn module ->
        File.write!(".credo.exs", """
        [
          config: #{inspect(module)}.called_directly(),
          callback: {#{inspect(module)}, :used_as_callback}
        ]
        """)

        unreachable = Reacher.analyze() |> MapSet.new()

        refute MapSet.member?(unreachable, {module, :called_directly, 0})
        refute MapSet.member?(unreachable, {module, :used_as_callback, 3})
        assert MapSet.member?(unreachable, {module, :unused, 0})
      end
    )
  end
end
