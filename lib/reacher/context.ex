defmodule Reacher.Context do
  @moduledoc """
  Shared inputs for one analysis run. Paths are absolute. Compiler references
  use string module and function names, as stored in the trace manifest.
  Each of `groups` lists candidates that are only called by each other, so
  they are reported together or not at all.
  """

  @type t :: %__MODULE__{
          modules: MapSet.t(module()),
          compile_path: String.t(),
          project_root: String.t(),
          compiler_traced_sources: MapSet.t(String.t()),
          compiler_references: MapSet.t({String.t(), String.t(), arity()}),
          default_families: %{mfa() => [mfa()]},
          groups: [[mfa()]]
        }

  @enforce_keys [:modules, :compile_path, :project_root]
  defstruct [
    :modules,
    :compile_path,
    :project_root,
    compiler_traced_sources: MapSet.new(),
    compiler_references: MapSet.new(),
    default_families: %{},
    groups: []
  ]
end
