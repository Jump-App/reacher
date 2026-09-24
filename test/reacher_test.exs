defmodule ReacherTest do
  use ExUnit.Case, async: false

  import Reacher.TestProject, only: [in_project: 2]

  describe "analyze/0" do
    test "reports unused functions from analyzed modules" do
      in_project(
        fn module ->
          """
          defmodule #{inspect(module)} do
            def entry, do: called()
            def called, do: :called
            def unused, do: :unused
          end
          """
        end,
        fn module ->
          unreachable = Reacher.analyze() |> MapSet.new()

          assert MapSet.member?(unreachable, {module, :unused, 0})
          refute MapSet.member?(unreachable, {module, :called, 0})
        end
      )
    end
  end

  describe "statically resolvable dynamic calls" do
    test "does not report functions called through literal Module.concat expressions" do
      in_project(
        fn module ->
          target = Module.concat(module, Target)
          wrapper = Module.concat(module, Wrapper)

          """
          defmodule #{inspect(wrapper)} do
            defmacro register(module_parts) do
              quote generated: true do
                def generated_entry do
                  Module.concat(unquote(module_parts)).called_from_macro()
                end
              end
            end
          end

          defmodule #{inspect(target)} do
            def called_from_concat_one, do: :called
            def called_from_concat_two, do: :called
            def called_from_list_concat, do: :called
            def called_from_macro, do: :called
            def resolve_but_unused, do: :unused
          end

          defmodule #{inspect(module)} do
            @module_parts [#{inspect(module)}]
            require #{inspect(wrapper)}

            #{inspect(wrapper)}.register([#{inspect(module)}, "Target"])

            def entry do
              Module.concat([#{inspect(module)}, "Target"]).called_from_concat_one()
              Module.concat(#{inspect(module)}, "Target").called_from_concat_two()
              Module.concat(@module_parts ++ ["Target"]).called_from_list_concat()
            end
          end
          """
        end,
        fn module ->
          target = Module.concat(module, Target)
          unreachable = Reacher.analyze() |> MapSet.new()

          refute MapSet.member?(unreachable, {target, :called_from_concat_one, 0})
          refute MapSet.member?(unreachable, {target, :called_from_concat_two, 0})
          refute MapSet.member?(unreachable, {target, :called_from_list_concat, 0})
          refute MapSet.member?(unreachable, {target, :called_from_macro, 0})
          assert MapSet.member?(unreachable, {target, :resolve_but_unused, 0})
        end
      )
    end

    test "still reports calls whose target module cannot be resolved statically" do
      in_project(
        fn module ->
          target = Module.concat(module, Target)

          """
          defmodule #{inspect(target)} do
            def resolve_dynamic, do: :called
          end

          defmodule #{inspect(module)} do
            def entry(module), do: module.resolve_dynamic()
          end
          """
        end,
        fn module ->
          target = Module.concat(module, Target)
          unreachable = Reacher.analyze() |> MapSet.new()

          assert MapSet.member?(unreachable, {target, :resolve_dynamic, 0})
        end
      )
    end
  end

  describe "module filtering" do
    test "limits results to the requested module" do
      in_project(
        fn module ->
          other = Module.concat(module, Other)

          """
          defmodule #{inspect(module)} do
            def unused, do: :unused
          end

          defmodule #{inspect(other)} do
            def unused, do: :unused
          end
          """
        end,
        fn module ->
          other = Module.concat(module, Other)
          target_message = "#{inspect(module)}.unused/0"
          other_message = "#{inspect(other)}.unused/0"

          previous_shell = Mix.shell()
          Mix.shell(Mix.Shell.Process)

          try do
            Reacher.analyze(module)

            assert_received {:mix_shell, :info, [^target_message]}
            refute_received {:mix_shell, :info, [^other_message]}
          after
            Mix.shell(previous_shell)
          end
        end
      )
    end

    test "rejects modules that are not loaded in the project" do
      in_project(fn _module -> "" end, fn _module ->
        unreachable = Reacher.analyze() |> MapSet.new()

        refute Enum.any?(unreachable, fn {module, _, _} -> module == String end)
      end)
    end
  end

  test "does not report functions from the project exclusion list" do
    in_project(
      fn module ->
        """
        defmodule #{inspect(module)} do
          def example_data, do: %{}
          def unused, do: :unused
        end
        """
      end,
      fn module ->
        File.write!(".reacher.exs", "[exclude: [{:example_data, 0}]]")

        unreachable = Reacher.analyze() |> MapSet.new()

        refute MapSet.member?(unreachable, {module, :example_data, 0})
        assert MapSet.member?(unreachable, {module, :unused, 0})
      end
    )
  end

  describe "excluded exports" do
    test "does not report macros" do
      in_project(
        fn module ->
          """
          defmodule #{inspect(module)} do
            defmacro unused_macro, do: :unused
            def unused, do: :unused
          end
          """
        end,
        fn module ->
          unreachable = Reacher.analyze() |> MapSet.new()

          refute Enum.any?(unreachable, fn {mod, name, _arity} ->
                   mod == module and String.starts_with?(Atom.to_string(name), "MACRO-")
                 end)

          assert MapSet.member?(unreachable, {module, :unused, 0})
        end
      )
    end

    test "does not report generated struct functions" do
      in_project(
        fn module ->
          """
          defmodule #{inspect(module)} do
            defstruct [:value]
            def unused, do: :unused
          end
          """
        end,
        fn module ->
          unreachable = Reacher.analyze() |> MapSet.new()

          refute MapSet.member?(unreachable, {module, :__struct__, 0})
          refute MapSet.member?(unreachable, {module, :__struct__, 1})
          assert MapSet.member?(unreachable, {module, :unused, 0})
        end
      )
    end

    test "does not report behaviour callbacks" do
      in_project(
        fn module ->
          behaviour = Module.concat(module, Behaviour)

          """
          defmodule #{inspect(behaviour)} do
            @callback callback() :: atom()
          end

          defmodule #{inspect(module)} do
            @behaviour #{inspect(behaviour)}
            @impl true
            def callback, do: :callback
            def unused, do: :unused
          end
          """
        end,
        fn module ->
          unreachable = Reacher.analyze() |> MapSet.new()

          refute MapSet.member?(unreachable, {module, :callback, 0})
          assert MapSet.member?(unreachable, {module, :unused, 0})
        end
      )
    end

    test "does not report after-verify callbacks" do
      in_project(
        fn module ->
          """
          defmodule #{inspect(module)} do
            @after_verify {__MODULE__, :after_verify}
            def after_verify(_module), do: :ok
            def unused, do: :unused
          end
          """
        end,
        fn module ->
          unreachable = Reacher.analyze() |> MapSet.new()

          refute MapSet.member?(unreachable, {module, :after_verify, 1})
          assert MapSet.member?(unreachable, {module, :unused, 0})
        end
      )
    end

    test "does not report the Erlang info function" do
      in_project(
        fn module ->
          """
          defmodule #{inspect(module)} do
            def unused, do: :unused
          end
          """
        end,
        fn module ->
          unreachable = Reacher.analyze() |> MapSet.new()

          refute MapSet.member?(unreachable, {module, :__info__, 1})
        end
      )
    end

    test "does not report the __using__ macro export" do
      in_project(
        fn module ->
          """
          defmodule #{inspect(module)}.Utils do
            defmacro __using__(_) do
            end
          end

          defmodule #{inspect(module)} do
            use #{inspect(module)}.Utils
          end
          """
        end,
        fn module ->
          unreachable = Reacher.analyze() |> MapSet.new()

          refute MapSet.member?(
                   unreachable,
                   {Module.concat(module, Utils), :"MACRO-__using__", 2}
                 )
        end
      )
    end
  end
end
