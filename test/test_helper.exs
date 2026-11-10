exclude = if Version.match?(System.version(), "< 1.20.0"), do: [:elixir_1_20], else: []

ExUnit.start(exclude: exclude)
