# Reacher

Reacher reports public functions for which it cannot find a caller, which is considered dead code which should be avoided.

Use it via a mix task:

```sh
mix reacher
mix reacher MyApp.SomeModule
mix reacher --format json
```

The second form allows to only list functions defined in a certain module (although bear in mind that a full project analysis is required anyway; it's just a human convenience, not performance shortcut).

The JSON form prints a sorted array of objects with `module`, `function`, and `arity` fields. The output is stable, so it can be diffed between revisions (for example in CI) to report added and removed findings.

## Sources

Reacher mainly uses `:xref` in the compiled project to get a call graph. It also includes additional source recognizing some `Module.concat` call and a small compiler tracer to handle macros better.

After the broad list of unused candidates is created, it employs a number of filters to handle more specific cases, when a function is actually used, even though `:xref` or others don't detect it.

The built-in filters include:
- OTP (`handle_call`, `handle_info`, `handle_cast`, `init`, and others)
- Phoenix (controller actions, routing helpers, LiveView callbacks)
- Absinthe resolvers
- Credo checks
- Oban Pro callbacks
- Protocol callbacks
- Usages found via compiler traces

Filters for third-party libraries (Phoenix, Absinthe, Oban Pro) only run when the library is available in the analyzed project, so projects without them skip those checks.

You can also write your own project-specific filters (see below).

## Project configuration

Reacher configuration lies in `.reacher.exs` file in the Mix project root:

```elixir
[
  filterers: [
    {MyApp.Reacher.RegistryFilterer, functions: [execute: 1]}
  ],
  exclude: [
    MyApp.GeneratedModule,
    {:example_data, 0},
    {MyApp.Legacy, :entry, 2}
  ]
]
```

- `:filterers` – a list of custom project filterers, which gets appended after the built-in filterers
- `:exclude` – list of elements to ignore. It might contain whole modules, a 2-element tuple with function name and arity (regardless the module) or a full MFA.

## Writing a custom filterer

Custom filterers need to implement the `Reacher.Filterer` behaviour, which requires defining the `filter/3` function. For example:

```elixir
defmodule MyApp.Reacher.RegistryFilterer do
  @behaviour Reacher.Filterer

  @impl Reacher.Filterer
  def filter(candidates, _context, opts) do
    registered_modules = MyApp.Registry.implementations()
    functions = Keyword.fetch!(opts, :functions)

    Enum.reject(candidates, fn {module, name, arity} ->
      module in registered_modules and {name, arity} in functions
    end)
  end
end
```

`filter/3` receives the remaining `{module, function, arity}` candidates, a `Reacher.Context` struct, and its configured options. It must return an order-preserving subset of those candidates. The project is compiled before filtering, but its application is not started by Reacher, so filterers should not depend on running application processes.

The context exposes:

- `modules`: all modules included in the analysis, even if earlier filters
  removed their candidates
- `compile_path`: absolute path to the project's compiled BEAM files
- `project_root`: absolute path to the current Mix project
- `compiler_traced_sources`: a `MapSet` of absolute source paths covered by
  compiler traces
- `compiler_references`: a `MapSet` of `{module_string, function_string, arity}`
  references from the compiler trace manifest
- `default_families`: unused functions with default arguments, as a map from
  the full-arity MFA to every arity it compiles to. Candidates include all of
  these arities; removing any one of them keeps the whole function out of the
  report

## Using in CI

### Enabling compiler traces

For the most accurate results, the analyzed project should compile with Reacher's compiler tracer enabled. Add the dependency and the `:reacher` compiler to the project's `mix.exs`:

```elixir
def project do
  [
    # ...
    compilers: [:reacher] ++ Mix.compilers()
  ]
end
```

Without the compiler, the analysis still runs, but it has no trace data and falls back to scanning source files for literal calls, so functions that are only called at compile time may be reported as unused.

### Failing the build

`mix reacher` exits with a non-zero status when it reports any unused function, so a plain step is enough to gate a build:

```yaml
- run: mix reacher
```