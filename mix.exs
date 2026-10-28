defmodule KogenCredo.MixProject do
  use Mix.Project

  @repo "https://github.com/KogenAI/kogen_credo"
  @version "0.1.0"

  @spec project() :: keyword()
  def project do
    [
      app: :kogen_credo,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex package
      description: "Credo checks for AI-generated code and test-gate integrity",
      package: package(),

      # Docs
      name: "KogenCredo",
      source_url: @repo,
      docs: [
        extras: [
          "README.md",
          "CHANGELOG.md",
          "LICENSE",
          "docs/configuration.md",
          "docs/checks.md",
          "docs/migration.md",
          "docs/diff-checks.md"
        ],
        main: "readme",
        source_ref: "v#{@version}"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  @spec application() :: keyword()
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7 and >= 1.7.19"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @repo},
      files: [
        "lib",
        "docs",
        ".credo.example.exs",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md"
      ],
      maintainers: ["Almir Sarajčić"]
    ]
  end
end
