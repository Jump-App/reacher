defmodule Reacher.ConfigTest do
  use ExUnit.Case, async: true

  setup %{tmp_dir: dir} do
    %{path: Path.join(dir, ".reacher.exs")}
  end

  @moduletag :tmp_dir

  test "missing configuration uses defaults", %{path: path} do
    assert Reacher.Config.load(path) == []
  end

  test "accepts existing exclusion forms", %{path: path} do
    config = [exclude: [SomeModule, {:example_data, 0}, {SomeModule, :helper, 1}]]
    File.write!(path, inspect(config))
    assert Reacher.Config.load(path) == config
  end

  test "rejects malformed configuration with the path and cause", %{path: path} do
    for {source, message} <- [
          {"%{}", "expected a keyword list"},
          {"[filterrs: []]", "unknown option :filterrs"},
          {"[filterers: :bad]", ":filterers must be a list"},
          {"[filterers: [123]]", "invalid filterer 123"},
          {"[filterers: [{String, %{}}]]", "options for String must be a keyword list"},
          {"[filterers: [String]]", "filterer String must be loadable and export filter/3"},
          {"[filterers: [Reacher.MissingFilterer]]", "must be loadable and export filter/3"},
          {"[exclude: [{:helper, -1}]]", ":exclude must contain"}
        ] do
      File.write!(path, source)
      error = assert_raise ArgumentError, fn -> Reacher.Config.load(path) end
      assert error.message =~ path
      assert error.message =~ message
    end
  end

  test "does not swallow errors in configuration code", %{path: path} do
    File.write!(path, ~s(raise "broken config"))
    assert_raise RuntimeError, "broken config", fn -> Reacher.Config.load(path) end
  end

  test "does not treat an unreadable config as missing", %{path: path} do
    File.mkdir!(path)
    assert_raise File.Error, fn -> Reacher.Config.load(path) end
  end
end
