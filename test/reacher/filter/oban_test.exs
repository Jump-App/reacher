defmodule Reacher.Filter.ObanTest do
  use ExUnit.Case, async: false

  import Reacher.TestProject, only: [in_project: 2]

  test "does not report generated worker metadata or registered hook callbacks" do
    in_project(
      fn module ->
        worker = Module.concat(module, Worker)
        hook = Module.concat(module, Hook)
        attached_hook = Module.concat(module, AttachedHook)
        registration = Module.concat(module, Registration)
        unrelated = Module.concat(module, Unrelated)

        """
        defmodule Oban.Pro.Worker do
          def attach_hook(_hook), do: :ok
        end

        defmodule #{inspect(hook)} do
          def before_process(job), do: {:ok, job}
          def after_process(_state, _job, _result), do: :ok
          def on_cancelled(_reason, _job), do: :ok
          def on_discarded(_reason, _job), do: :ok
          def unused, do: :unused
        end

        defmodule #{inspect(attached_hook)} do
          def before_new(args, opts), do: {:ok, args, opts}
          def after_process(_job, _result), do: :ok
          def unused, do: :unused
        end

        defmodule #{inspect(worker)} do
          def __opts__, do: [hooks: [#{inspect(hook)}]]
          def __stage_opts__, do: [hooks: [#{inspect(hook)}]]
          def __stand_opts__, do: []
          def unused, do: :unused
        end

        defmodule #{inspect(registration)} do
          def attach, do: Oban.Pro.Worker.attach_hook(#{inspect(attached_hook)})
        end

        defmodule #{inspect(unrelated)} do
          def __stage_opts__, do: :not_an_oban_worker
          def after_process(_state, _job, _result), do: :not_an_oban_hook
        end
        """
      end,
      fn module ->
        worker = Module.concat(module, Worker)
        hook = Module.concat(module, Hook)
        attached_hook = Module.concat(module, AttachedHook)
        unrelated = Module.concat(module, Unrelated)
        unreachable = Reacher.analyze() |> MapSet.new()

        refute MapSet.member?(unreachable, {worker, :__stage_opts__, 0})
        refute MapSet.member?(unreachable, {worker, :__stand_opts__, 0})

        refute MapSet.member?(unreachable, {hook, :before_process, 1})
        refute MapSet.member?(unreachable, {hook, :after_process, 3})
        refute MapSet.member?(unreachable, {hook, :on_cancelled, 2})
        refute MapSet.member?(unreachable, {hook, :on_discarded, 2})
        refute MapSet.member?(unreachable, {attached_hook, :before_new, 2})
        refute MapSet.member?(unreachable, {attached_hook, :after_process, 2})

        assert MapSet.member?(unreachable, {worker, :unused, 0})
        assert MapSet.member?(unreachable, {hook, :unused, 0})
        assert MapSet.member?(unreachable, {attached_hook, :unused, 0})
        assert MapSet.member?(unreachable, {unrelated, :__stage_opts__, 0})
        assert MapSet.member?(unreachable, {unrelated, :after_process, 3})
      end
    )
  end
end
