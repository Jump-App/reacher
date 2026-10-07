defmodule Mix.Tasks.ReacherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [capture_io: 1]
  import Reacher.TestProject, only: [in_project: 2]

  test "prints findings grouped and sorted by module" do
    in_project(
      fn module ->
        target = Module.concat(module, Target)

        """
        defmodule #{inspect(module)} do
          def entry, do: called()
          def called, do: :called
          def unused_zeta(_value), do: :unused
        end

        defmodule #{inspect(target)} do
          def unused_alpha, do: :unused
        end
        """
      end,
      fn module ->
        target = Module.concat(module, Target)

        output = capture_io(fn -> Mix.Tasks.Reacher.run([]) end)

        assert output == """

               #{inspect(module)}
                 entry/0
                 unused_zeta/1

               #{inspect(target)}
                 unused_alpha/0


               Found 3 unused functions across 2 modules.
               """
      end
    )
  end

  test "limits findings to an optional module argument" do
    in_project(
      fn module ->
        target = Module.concat(module, Target)

        """
        defmodule #{inspect(module)} do
          def unused, do: :unused
        end

        defmodule #{inspect(target)} do
          def unused, do: :unused
        end
        """
      end,
      fn module ->
        target = Module.concat(module, Target)

        output = capture_io(fn -> Mix.Tasks.Reacher.run([inspect(target)]) end)

        assert output == """

               #{inspect(target)}
                 unused/0


               Found 1 unused function across 1 module.
               """

        refute output =~ "\n#{inspect(module)}\n"
      end
    )
  end

  test "prints a concise message when there are no findings" do
    in_project(
      fn module ->
        """
        defmodule #{inspect(module)} do
        end
        """
      end,
      fn _module ->
        assert capture_io(fn -> Mix.Tasks.Reacher.run([]) end) ==
                 "No unused functions found.\n"
      end
    )
  end

  test "prints unnecessary skip warnings" do
    in_project(
      fn module ->
        """
        defmodule #{inspect(module)} do
          def unused, do: :unused
        end
        """
      end,
      fn module ->
        File.write!(".reacher.exs", """
        [exclude: [NonExistent.Module, {#{inspect(module)}, :unused, 0}]]
        """)

        output = capture_io(fn -> Mix.Tasks.Reacher.run([]) end)

        assert output =~ "Unnecessary skips"
        assert output =~ "NonExistent.Module"
        refute output =~ "#{inspect(module)}.unused/0"
      end
    )
  end

  test "does not print unnecessary skip section when all exclusions match" do
    in_project(
      fn module ->
        """
        defmodule #{inspect(module)} do
          def unused, do: :unused
        end
        """
      end,
      fn module ->
        File.write!(".reacher.exs", """
        [exclude: [{#{inspect(module)}, :unused, 0}]]
        """)

        output = capture_io(fn -> Mix.Tasks.Reacher.run([]) end)

        refute output =~ "Unnecessary skips"
      end
    )
  end

  test "prints sorted machine-readable findings" do
    in_project(
      fn module ->
        """
        defmodule #{inspect(module)} do
          def zeta, do: :unused
          def alpha(value), do: value
        end
        """
      end,
      fn module ->
        output = capture_io(fn -> Mix.Tasks.Reacher.run(["--format", "json"]) end)

        assert :json.decode(output) == [
                 %{"arity" => 1, "function" => "alpha", "module" => inspect(module)},
                 %{"arity" => 0, "function" => "zeta", "module" => inspect(module)}
               ]
      end
    )
  end
end
