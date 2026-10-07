defmodule Reacher.Filter.ProjectTest do
  use ExUnit.Case, async: true

  alias Reacher.Filter.Project

  @candidates [
    {MyApp.Accounts, :list_users, 0},
    {MyApp.Accounts, :get_user, 1},
    {MyApp.Posts, :create_post, 2}
  ]

  describe "unnecessary_skips/2" do
    test "returns module exclusions that match no candidate" do
      opts = [exclude: [MyApp.Nonexistent]]
      assert Project.unnecessary_skips(@candidates, opts) == [MyApp.Nonexistent]
    end

    test "does not return module exclusions that match a candidate" do
      opts = [exclude: [MyApp.Accounts]]
      assert Project.unnecessary_skips(@candidates, opts) == []
    end

    test "returns MFA exclusions that match no candidate" do
      opts = [exclude: [{MyApp.Accounts, :delete_user, 1}]]
      assert Project.unnecessary_skips(@candidates, opts) == [{MyApp.Accounts, :delete_user, 1}]
    end

    test "does not return MFA exclusions that match a candidate" do
      opts = [exclude: [{MyApp.Accounts, :get_user, 1}]]
      assert Project.unnecessary_skips(@candidates, opts) == []
    end

    test "returns {name, arity} exclusions that match no candidate" do
      opts = [exclude: [{:nonexistent, 0}]]
      assert Project.unnecessary_skips(@candidates, opts) == [{:nonexistent, 0}]
    end

    test "does not return {name, arity} exclusions that match a candidate" do
      opts = [exclude: [{:get_user, 1}]]
      assert Project.unnecessary_skips(@candidates, opts) == []
    end

    test "returns only the unnecessary skips from a mixed list" do
      opts = [
        exclude: [
          MyApp.Accounts,
          MyApp.Gone,
          {:get_user, 1},
          {:vanished, 3},
          {MyApp.Posts, :create_post, 2},
          {MyApp.Posts, :delete_post, 1}
        ]
      ]

      assert Project.unnecessary_skips(@candidates, opts) == [
               MyApp.Gone,
               {:vanished, 3},
               {MyApp.Posts, :delete_post, 1}
             ]
    end

    test "returns empty list when there are no exclusions" do
      assert Project.unnecessary_skips(@candidates, []) == []
      assert Project.unnecessary_skips(@candidates, exclude: []) == []
    end
  end
end
