# Copy or merge these entries into your default configuration before running mix credo --strict.
# The async_safe_tests preset applies only to literal async: true modules.
# Declare custom case_templates on test-state checks; see README.md.
# Explicit opt-in configuration. Review each detector and its parameters in docs/checks.md.
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: [
          "mix.exs",
          "lib/",
          "test/",
          "config/",
          "priv/repo/migrations/",
          "priv/repo/seeds.exs",
          "priv/repo/seeds/"
        ]
      },
      checks: %{
        enabled: [
          {KogenCredo.Check.Readability.EmptySetupBlock, []},
          {KogenCredo.Check.Readability.ErrorReasonString, []},
          {KogenCredo.Check.Readability.JustifiedCoverageIgnore, []},
          {KogenCredo.Check.Readability.MapGetAtomKey, []},
          {KogenCredo.Check.Refactor.DomainSize, []},
          {KogenCredo.Check.Refactor.DuplicateHelper, []},
          {KogenCredo.Check.Refactor.SizeLimits, []},
          {KogenCredo.Check.Warning.BroadRescue, []},
          {KogenCredo.Check.Warning.CtxBag, []},
          {KogenCredo.Check.Warning.DiscardedResult, []},
          {KogenCredo.Check.Warning.DomainReach, []},
          {KogenCredo.Check.Warning.FailOpenWith, []},
          {KogenCredo.Check.Warning.ForbiddenCall, [presets: [:async_safe_tests]]},
          {KogenCredo.Check.Warning.GlobalNameInventory, []},
          {KogenCredo.Check.Warning.GlobalStateInAsync, []},
          {KogenCredo.Check.Warning.LimitWithoutStableOrder, []},
          {KogenCredo.Check.Warning.NoCredoDisable, []},
          {KogenCredo.Check.Warning.NoGlobalTeardown, []},
          {KogenCredo.Check.Warning.PathExpandPriv, []},
          {KogenCredo.Check.Warning.RepoAllThenTrim, []},
          {KogenCredo.Check.Warning.RepoInLoop, []},
          {KogenCredo.Check.Warning.RuntimeEnvDevDefault, []},
          {KogenCredo.Check.Warning.SerialReason, []},
          {KogenCredo.Check.Warning.SharedResourceGroup, []},
          {KogenCredo.Check.Warning.SkippedTest, []},
          {KogenCredo.Check.Warning.StringKeyAccess, []},
          {KogenCredo.Check.Warning.StubBody, []},
          {KogenCredo.Check.Warning.TestFsHygiene, []},
          {KogenCredo.Check.Warning.TestHasNoAssertions, []},
          {KogenCredo.Check.Warning.TestModuleShape, []},
          {KogenCredo.Check.Warning.UnboundedWait, []},
          {KogenCredo.Check.Warning.UnescapedLikeInput, []},
          {KogenCredo.Check.Warning.VacuousTest, []},
          {KogenCredo.Check.Warning.VariableModuleCall, []},
          {KogenCredo.Check.Warning.WeakAssertion, []}
        ],
        disabled: []
      }
    }
  ]
}
