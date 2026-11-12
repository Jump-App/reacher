defmodule Reacher.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/Jump-App/reacher"

  def project do
    [
      app: :reacher,
      version: @version,
      name: "Reacher",
      description:
        "Finds public Elixir functions with no known callers to help identify dead code",
      source_url: @source_url,
      package: package(),
      elixir: "~> 1.18",
      test_paths: ["test", "lib"],
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :tools]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    []
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "CHANGELOG.md", "LICENSE"],
      maintainers: ["Paweł Świątkowski"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
