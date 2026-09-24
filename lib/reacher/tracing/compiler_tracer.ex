defmodule Reacher.Tracing.CompilerTracer do
  @moduledoc false

  @table __MODULE__
  @remote_calls [:imported_function, :remote_function]

  def start do
    stop()
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :ok
  end

  def stop do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table)
    end

    :ok
  end

  def snapshot do
    if :ets.whereis(@table) == :undefined do
      %{}
    else
      Enum.reduce(:ets.tab2list(@table), %{}, fn
        {{:source, source}, _value}, sources ->
          Map.put_new(sources, source, MapSet.new())

        {{:call, source, module, name, arity}, _value}, sources ->
          Map.update(sources, source, MapSet.new([{module, name, arity}]), fn calls ->
            MapSet.put(calls, {module, name, arity})
          end)
      end)
    end
  end

  def trace(:start, env) do
    record_source(env.file)
    :ok
  end

  def trace({kind, _meta, module, name, arity}, env)
      when kind in @remote_calls and is_nil(env.function) do
    record_call(env.file, module, name, arity)
    :ok
  end

  def trace({:local_function, _meta, name, arity}, env) when is_nil(env.function) do
    record_call(env.file, env.module, name, arity)
    :ok
  end

  def trace(_event, _env), do: :ok

  defp record_source(source) do
    insert({{:source, source}, true})
  end

  defp record_call(source, module, name, arity) do
    insert({{:call, source, module, name, arity}, true})
  end

  defp insert(entry) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, entry)
    end
  end
end
