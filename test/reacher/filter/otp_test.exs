defmodule Reacher.Filter.OTPTest do
  use ExUnit.Case, async: false

  import Reacher.TestProject, only: [in_project: 2]

  test "does not report OTP child entry points" do
    in_project(
      fn module ->
        server = Module.concat(module, Server)
        child = Module.concat(module, Child)
        unrelated = Module.concat(module, Unrelated)

        """
        defmodule #{inspect(server)} do
          use GenServer

          def child_spec(opts) do
            %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
          end

          def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

          @impl GenServer
          def init(state), do: {:ok, state}

          def unused, do: :unused
        end

        defmodule #{inspect(child)} do
          def child_spec(_opts), do: %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}
          def unused, do: :unused
        end

        defmodule #{inspect(unrelated)} do
          def start_link(_opts), do: :not_an_otp_child
        end
        """
      end,
      fn module ->
        server = Module.concat(module, Server)
        child = Module.concat(module, Child)
        unrelated = Module.concat(module, Unrelated)
        unreachable = Reacher.analyze() |> MapSet.new()

        refute MapSet.member?(unreachable, {server, :child_spec, 1})
        refute MapSet.member?(unreachable, {server, :start_link, 1})
        refute MapSet.member?(unreachable, {child, :child_spec, 1})

        assert MapSet.member?(unreachable, {server, :unused, 0})
        assert MapSet.member?(unreachable, {child, :unused, 0})
        assert MapSet.member?(unreachable, {unrelated, :start_link, 1})
      end
    )
  end
end
