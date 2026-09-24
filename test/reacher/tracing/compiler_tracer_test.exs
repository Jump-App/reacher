defmodule Reacher.Tracing.CompilerTracerTest do
  use ExUnit.Case, async: false

  import Reacher.TestProject, only: [in_project: 3]

  test "persists resolved compile-time calls without guessing macro arguments" do
    in_project(
      fn module ->
        target = Module.concat(module, Target)
        provider = Module.concat(module, Provider)
        consumer = Module.concat(module, Consumer)

        """
        defmodule #{inspect(target)} do
          def from_attribute, do: :attribute
          def from_expansion, do: :expansion
          def from_macro_body, do: :macro_body
          def from_unexpanded_quote, do: :unexpanded_quote
        end

        defmodule #{inspect(provider)} do
          def variant, do: :not_called

          defmacro __using__(_variant), do: nil

          defmacro emit_call do
            quote do
              #{inspect(target)}.from_expansion()
            end
          end

          defmacro call_during_expansion do
            #{inspect(target)}.from_macro_body()
            nil
          end

          defmacro unused_macro do
            quote do
              #{inspect(target)}.from_unexpanded_quote()
            end
          end
        end

        defmodule #{inspect(consumer)} do
          alias #{inspect(target)}, as: Target
          require #{inspect(provider)}

          @value Target.from_attribute()
          #{inspect(provider)}.emit_call()
          #{inspect(provider)}.call_during_expansion()
          use #{inspect(provider)}, :variant

          def value, do: @value
        end
        """
      end,
      [compiler_trace: true],
      fn module ->
        target = Module.concat(module, Target)
        provider = Module.concat(module, Provider)
        unreachable = Reacher.analyze() |> MapSet.new()

        assert Reacher.Tracing.Manifest.referenced?({target, :from_attribute, 0})
        assert Reacher.Tracing.Manifest.referenced?({target, :from_expansion, 0})
        refute Reacher.Tracing.Manifest.referenced?({target, :from_macro_body, 0})
        refute Reacher.Tracing.Manifest.referenced?({target, :from_unexpanded_quote, 0})
        refute Reacher.Tracing.Manifest.referenced?({provider, :variant, 0})

        refute MapSet.member?(unreachable, {target, :from_attribute, 0})
        refute MapSet.member?(unreachable, {target, :from_expansion, 0})
        refute MapSet.member?(unreachable, {target, :from_macro_body, 0})
        assert MapSet.member?(unreachable, {target, :from_unexpanded_quote, 0})
        assert MapSet.member?(unreachable, {provider, :variant, 0})
      end
    )
  end

  test "replaces calls for a source file when it is recompiled" do
    in_project(
      fn module -> fixture_source(module, :old_call) end,
      [compiler_trace: true],
      fn module ->
        target = Module.concat(module, Target)

        assert Reacher.Tracing.Manifest.referenced?({target, :old_call, 0})

        Process.sleep(1_000)
        File.write!("lib/fixture.ex", fixture_source(module, :new_call))

        Mix.Task.reenable("compile")
        Mix.Task.reenable("compile.all")

        Mix.Task.Compiler.compilers()
        |> Enum.each(&Mix.Task.reenable("compile.#{&1}"))

        Mix.Task.run("compile")

        refute Reacher.Tracing.Manifest.referenced?({target, :old_call, 0})
        assert Reacher.Tracing.Manifest.referenced?({target, :new_call, 0})
      end
    )
  end

  defp fixture_source(module, call) do
    target = Module.concat(module, Target)
    consumer = Module.concat(module, Consumer)

    """
    defmodule #{inspect(target)} do
      def old_call, do: :old
      def new_call, do: :new
    end

    defmodule #{inspect(consumer)} do
      @value #{inspect(target)}.#{call}()
      def value, do: @value
    end
    """
  end
end
