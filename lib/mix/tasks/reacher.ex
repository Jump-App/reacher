defmodule Mix.Tasks.Reacher do
  @shortdoc "Reports unreachable exported functions"
  @moduledoc """
  Reports exported functions that Reacher cannot find a caller for.

      mix reacher
      mix reacher MyApp.SomeModule
      mix reacher --format json

  Passing a module limits the report to that module.
  """

  use Mix.Task

  @requirements ["compile"]

  @impl Mix.Task
  def run(args) do
    {opts, args, invalid} = OptionParser.parse(args, strict: [format: :string])
    selected_module = selected_module(args)

    if invalid != [] or Keyword.get(opts, :format, "text") not in ["text", "json"] do
      Mix.raise("Usage: mix reacher [--format text|json] [Module]")
    end

    %{unreachable: unreachable, unnecessary_skips: unnecessary_skips} = Reacher.analyze_full()
    results = filter(unreachable, selected_module)

    format = Keyword.get(opts, :format, "text")

    case format do
      "json" ->
        print_json(results)

      "text" ->
        print_results(results)
        print_unnecessary_skips(unnecessary_skips)
    end

    if results != [] do
      Mix.raise(
        "Reacher found #{length(results)} unused #{pluralize("function", length(results))}"
      )
    end
  end

  defp selected_module([]), do: nil
  defp selected_module([module]), do: Module.concat([module])
  defp selected_module(_args), do: Mix.raise("Usage: mix reacher [Module]")

  defp filter(unreachable, nil), do: unreachable

  defp filter(unreachable, selected_module) do
    Enum.filter(unreachable, fn {module, _name, _arity} ->
      module == selected_module
    end)
  end

  defp print_json(unreachable) do
    unreachable
    |> Enum.map(fn {module, name, arity} ->
      %{module: inspect(module), function: Atom.to_string(name), arity: arity}
    end)
    |> Enum.sort_by(fn finding -> {finding.module, finding.function, finding.arity} end)
    |> :json.encode()
    |> IO.puts()
  end

  defp print_results([]) do
    Mix.shell().info("No unused functions found.")
  end

  defp print_results(unreachable) do
    grouped = Enum.group_by(unreachable, fn {module, _name, _arity} -> module end)
    function_count = length(unreachable)
    module_count = map_size(grouped)

    grouped
    |> Enum.sort_by(fn {module, _functions} -> module end)
    |> Enum.each(fn {module, functions} ->
      Mix.shell().info("")
      Mix.shell().info(inspect(module))

      functions
      |> Enum.sort_by(fn {_module, name, arity} -> {name, arity} end)
      |> Enum.each(fn {_module, name, arity} ->
        Mix.shell().info("  #{name}/#{arity}")
      end)
    end)

    Mix.shell().info(
      "\n\nFound #{function_count} unused #{pluralize("function", function_count)} " <>
        "across #{module_count} #{pluralize("module", module_count)}."
    )
  end

  defp print_unnecessary_skips([]), do: :ok

  defp print_unnecessary_skips(unnecessary_skips) do
    Mix.shell().info("")
    Mix.shell().info("Unnecessary skips (not matching any candidate):")

    Enum.each(unnecessary_skips, fn
      {m, n, a} when is_atom(m) and is_atom(n) and is_integer(a) ->
        Mix.shell().info("  #{inspect(m)}.#{n}/#{a}")

      {n, a} when is_atom(n) and is_integer(a) ->
        Mix.shell().info("  #{n}/#{a}")

      module when is_atom(module) ->
        Mix.shell().info("  #{inspect(module)}")
    end)
  end

  defp pluralize(word, 1), do: word
  defp pluralize(word, _count), do: word <> "s"
end
