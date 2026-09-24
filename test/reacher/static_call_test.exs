defmodule Reacher.StaticCallTest do
  use ExUnit.Case, async: true

  alias Reacher.StaticCall

  describe "resolve/1" do
    test "resolves a call through Module.concat/1" do
      module_ast = module_concat([["MyApp", Billing, Invoice, Resolvers]])
      ast = remote_call(module_ast, :registered, [:args, :context])

      assert StaticCall.resolve(ast) ==
               {:ok, {MyApp.Billing.Invoice.Resolvers, :registered, 2}}
    end

    test "resolves Module.concat/2 and literal list concatenation" do
      concat_two_ast =
        module_concat([MyApp.Billing.Invoice, Resolvers])
        |> remote_call(:registered, [:args])

      list_concat_ast =
        erlang_list_concat(["MyApp", Admin], [GraphQL, Resolvers])
        |> then(&module_concat([&1]))
        |> remote_call(:registered, [:parent, :args, :resolution])

      assert StaticCall.resolve(concat_two_ast) ==
               {:ok, {MyApp.Billing.Invoice.Resolvers, :registered, 1}}

      assert StaticCall.resolve(list_concat_ast) ==
               {:ok, {MyApp.Admin.GraphQL.Resolvers, :registered, 3}}
    end

    test "rejects a call whose module is not statically resolvable" do
      ast = remote_call({:module, [], nil}, :registered, [])

      assert StaticCall.resolve(ast) == :error
    end
  end

  defp module_concat(args), do: {{:., [], [Module, :concat]}, [], args}

  defp erlang_list_concat(left, right),
    do: {{:., [], [:erlang, :++]}, [], [left, right]}

  defp remote_call(module_ast, function, args),
    do: {{:., [], [module_ast, function]}, [], args}
end
