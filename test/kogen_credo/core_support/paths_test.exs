defmodule KogenCredo.CoreSupport.PathsTest do
  use ExUnit.Case, async: true

  alias KogenCredo.CoreSupport.Paths

  describe "in_paths?/2" do
    test "matches prefixes, umbrella sub-apps and exact files" do
      assert Paths.in_paths?("lib/a/b.ex", ["lib/"])
      assert Paths.in_paths?("apps/web/lib/a.ex", ["lib/"])
      assert Paths.in_paths?("./lib/a.ex", ["lib"])
      assert Paths.in_paths?("lib/shop/billing.ex", ["lib/shop/billing.ex"])
    end

    test "respects segment boundaries" do
      refute Paths.in_paths?("lib/shop/billing_extras/a.ex", ["lib/shop/billing"])
      refute Paths.in_paths?("library/a.ex", ["lib"])
      assert Paths.in_paths?("lib/shop/billing/a.ex", ["lib/shop/billing"])
    end

    test "normalises Windows separators" do
      assert Paths.in_paths?("lib\\a\\b.ex", ["lib/a"])
    end
  end

  describe "in_scope?/3" do
    test "empty included means everywhere; excluded wins" do
      assert Paths.in_scope?("anything.ex", [])
      refute Paths.in_scope?("lib/gen/a.ex", ["lib"], ["lib/gen"])
    end
  end

  describe "matches_any?/2" do
    test "exact, suffix and glob patterns" do
      assert Paths.matches_any?("test/a_test.exs", ["test/a_test.exs"])
      assert Paths.matches_any?("apps/x/test/a_test.exs", ["test/a_test.exs"])
      assert Paths.matches_any?("lib/app/user_codec.ex", ["lib/**/*_codec.ex"])
      assert Paths.matches_any?("lib/user_codec.ex", ["lib/**/*_codec.ex"])
      assert Paths.matches_any?("apps/x/lib/app/wire/a.ex", ["lib/**/wire/**/*.ex"])
      refute Paths.matches_any?("lib/app/user.ex", ["lib/**/*_codec.ex"])
      refute Paths.matches_any?("lib/a/b.ex", ["lib/*.ex"])
    end
  end
end
