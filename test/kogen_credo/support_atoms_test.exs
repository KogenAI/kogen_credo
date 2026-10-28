defmodule KogenCredo.SupportAtomsTest do
  use ExUnit.Case, async: true

  alias KogenCredo.QuerySupport
  alias KogenCredo.SafetySupport

  describe "QuerySupport.names/1 and listed?/2" do
    test "atoms and strings become names, whether or not an atom exists for them" do
      unknown = "never_an_atom_#{System.unique_integer([:positive])}"
      names = QuerySupport.names([:insert, "update", unknown])

      assert names == ["insert", "update", unknown]
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end

    test "an atom of the analysed code is matched by name" do
      names = QuerySupport.names([:insert, "update"])

      assert QuerySupport.listed?(:insert, names)
      assert QuerySupport.listed?(:update, names)
      refute QuerySupport.listed?(:delete, names)
      refute QuerySupport.listed?("insert", names)
    end

    test "atom_label/1 shows a name the way inspect/1 shows the atom" do
      for atom <- [:user_id, :ok?, :save!, :Upper, :"with space", :"a-b"] do
        name = Atom.to_string(atom)
        assert QuerySupport.atom_label(name) == inspect(atom)
      end
    end
  end

  describe "SafetySupport.module?/2" do
    test "compares expanded alias segments with a module" do
      assert SafetySupport.module?([:Enum], Enum)
      assert SafetySupport.module?([:MyApp, :Repo], MyApp.Repo)
      refute SafetySupport.module?([:Stream], Enum)
      refute SafetySupport.module?([:MyApp], MyApp.Repo)
    end

    test "anything that is not a list of atoms never matches" do
      refute SafetySupport.module?([:Enum, "Sub"], Enum.Sub)
      refute SafetySupport.module?([{:__MODULE__, [], nil}], Enum)
      refute SafetySupport.module?(nil, Enum)
    end
  end
end
