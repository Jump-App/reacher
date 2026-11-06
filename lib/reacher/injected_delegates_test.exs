defmodule Reacher.InjectedDelegatesTest do
  use ExUnit.Case, async: false

  alias Reacher.InjectedDelegates

  @moduletag :tmp_dir

  test "detects delegates injected by a macro", %{tmp_dir: tmp_dir} do
    {beam, source, definitions} = compile(tmp_dir, docs: true)

    assert {injected, %{^source => {:ok, _lines}}} =
             InjectedDelegates.detect(beam, source, definitions, %{})

    assert injected == MapSet.new([{:injected, 1}])
  end

  test "detects nothing without a docs chunk", %{tmp_dir: tmp_dir} do
    {beam, source, definitions} = compile(tmp_dir, docs: false)

    assert {injected, _cache} = InjectedDelegates.detect(beam, source, definitions, %{})
    assert injected == MapSet.new()
  end

  test "detects delegates when the source is newer than the BEAM", %{tmp_dir: tmp_dir} do
    {beam, source, definitions} = compile(tmp_dir, docs: true)
    File.touch!(source, System.os_time(:second) + 60)

    assert {injected, _cache} = InjectedDelegates.detect(beam, source, definitions, %{})
    assert injected == MapSet.new([{:injected, 1}])
  end

  test "detects nothing when the source cannot be parsed", %{tmp_dir: tmp_dir} do
    {beam, source, definitions} = compile(tmp_dir, docs: true)
    File.write!(source, "defmodule Broken do")

    assert {injected, _cache} = InjectedDelegates.detect(beam, source, definitions, %{})
    assert injected == MapSet.new()
  end

  test "detects nothing when the source is missing", %{tmp_dir: tmp_dir} do
    {beam, source, definitions} = compile(tmp_dir, docs: true)
    File.rm!(source)

    assert {injected, _cache} = InjectedDelegates.detect(beam, source, definitions, %{})
    assert injected == MapSet.new()
  end

  defp compile(tmp_dir, docs: docs) do
    id = System.unique_integer([:positive])
    provider = Module.concat([__MODULE__, "Provider#{id}"])
    consumer = Module.concat([__MODULE__, "Consumer#{id}"])
    source = Path.join(tmp_dir, "consumer.ex")

    File.write!(source, """
    defmodule #{inspect(provider)} do
      defmacro __using__(_opts) do
        quote do
          defdelegate injected(value), to: String, as: :length
        end
      end
    end

    defmodule #{inspect(consumer)} do
      use #{inspect(provider)}

      defdelegate handwritten(value), to: String, as: :length
    end
    """)

    previous = Code.compiler_options(docs: docs, debug_info: true)

    try do
      {:ok, _modules, _diagnostics} =
        Kernel.ParallelCompiler.compile_to_path([source], tmp_dir, return_diagnostics: true)
    after
      Code.compiler_options(previous)

      for module <- [consumer, provider] do
        :code.delete(module)
        :code.purge(module)
      end
    end

    beam = Path.join(tmp_dir, "#{consumer}.beam")

    {:ok, {^consumer, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(String.to_charlist(beam), [:debug_info])

    {:ok, %{definitions: definitions}} = backend.debug_info(:elixir_v1, consumer, data, [])
    {beam, source, definitions}
  end
end
