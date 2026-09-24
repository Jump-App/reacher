defmodule Reacher.Filter.ProtocolTest do
  use ExUnit.Case, async: false

  import Reacher.TestProject, only: [in_project: 2]

  test "does not report protocol callbacks" do
    in_project(
      fn module ->
        protocol = Module.concat(module, Formatter)
        value = Module.concat(module, Value)
        unrelated = Module.concat(module, Unrelated)

        """
        defprotocol #{inspect(protocol)} do
          def format(value)
        end

        defmodule #{inspect(value)} do
          defstruct []
        end

        defimpl #{inspect(protocol)}, for: #{inspect(value)} do
          def format(_value), do: :formatted
          def unused, do: :unused
        end

        defmodule #{inspect(unrelated)} do
          def format(_value), do: :unrelated
        end
        """
      end,
      fn module ->
        protocol = Module.concat(module, Formatter)
        value = Module.concat(module, Value)
        unrelated = Module.concat(module, Unrelated)
        implementation = apply(protocol, :impl_for, [struct(value)])
        unreachable = Reacher.analyze() |> MapSet.new()

        refute MapSet.member?(unreachable, {implementation, :format, 1})
        assert MapSet.member?(unreachable, {implementation, :unused, 0})
        assert MapSet.member?(unreachable, {unrelated, :format, 1})
      end
    )
  end
end
