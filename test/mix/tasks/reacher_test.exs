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

        output =
          capture_io(fn ->
            assert_raise Mix.Error, "Reacher found 3 unused functions", fn ->
              Mix.Tasks.Reacher.run([])
            end
          end)

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

        output =
          capture_io(fn ->
            assert_raise Mix.Error, "Reacher found 1 unused function", fn ->
              Mix.Tasks.Reacher.run([inspect(target)])
            end
          end)

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
        output =
          capture_io(fn ->
            assert_raise Mix.Error, "Reacher found 2 unused functions", fn ->
              Mix.Tasks.Reacher.run(["--format", "json"])
            end
          end)

        assert %{
                 "unused" => [
                   %{"arity" => 1, "function" => "alpha", "module" => module_name},
                   %{"arity" => 0, "function" => "zeta", "module" => module_name}
                 ],
                 "unnecessary_skips" => []
               } = :json.decode(output)

        assert module_name == inspect(module)
      end
    )
  end

  test "includes unnecessary skips in machine-readable output" do
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
        [exclude: [NonExistent.Module, {NonExistent.Other, :foo, 1}, {:bar, 2}, {#{inspect(module)}, :unused, 0}]]
        """)

        output = capture_io(fn -> Mix.Tasks.Reacher.run(["--format", "json"]) end)

        assert %{"unused" => [], "unnecessary_skips" => skips} = :json.decode(output)

        assert skips == [
                 %{"module" => :null, "function" => "bar", "arity" => 2},
                 %{"module" => "NonExistent.Module", "function" => :null, "arity" => :null},
                 %{"module" => "NonExistent.Other", "function" => "foo", "arity" => 1}
               ]
      end
    )
  end

  test "distinguishes nil atom skips from absent fields in machine-readable output" do
    in_project(
      fn module ->
        """
        defmodule #{inspect(module)} do
          def used, do: :ok
        end
        """
      end,
      fn module ->
        File.write!(".reacher.exs", """
        [exclude: [nil, {nil, :foo, 1}, {:foo, 1}, {#{inspect(module)}, :used, 0}]]
        """)

        output = capture_io(fn -> Mix.Tasks.Reacher.run(["--format", "json"]) end)

        assert %{"unnecessary_skips" => skips} = :json.decode(output)

        assert Enum.sort(skips) ==
                 Enum.sort([
                   %{"module" => "nil", "function" => :null, "arity" => :null},
                   %{"module" => "nil", "function" => "foo", "arity" => 1},
                   %{"module" => :null, "function" => "foo", "arity" => 1}
                 ])
      end
    )
  end
end
