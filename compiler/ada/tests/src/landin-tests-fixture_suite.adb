with Ada.Strings.Fixed;

with Landin.Platform.Native;
with Landin.Testing.Fakes;
with Landin.Testing.Fixtures;

package body Landin.Tests.Fixture_Suite is

   use Landin.Testing.Fixtures;

   LF : constant Character := Character'Val (10);

   --  The repository's real fixture trees, relative to the directory the
   --  harness is run from (compiler/ada).
   Valid_Root   : constant String := "../tests/fixtures";
   Invalid_Root : constant String := "../tests/harness-cases/malformed";

   function Mentions
     (In_Catalogue : Catalogue; Needle : String) return Boolean;

   function Mentions
     (In_Catalogue : Catalogue; Needle : String) return Boolean
   is
   begin
      for Index in 1 .. Problem_Count (In_Catalogue) loop
         if Ada.Strings.Fixed.Index
              (Nth_Problem (In_Catalogue, Index), Needle) > 0
         then
            return True;
         end if;
      end loop;
      return False;
   end Mentions;

   procedure Classes_Have_Directories (Item : in out Landin.Testing.Context);

   procedure Classes_Have_Directories
     (Item : in out Landin.Testing.Context)
   is
      Found : Boolean;
      Named : Fixture_Class;
   begin
      --  Every class, because a renamed directory makes Discover look at a
      --  path that does not exist and quietly find nothing there.
      Landin.Testing.Check_Equal
        (Item, Class_Directory (Unit), "unit", "unit directory");
      Landin.Testing.Check_Equal
        (Item, Class_Directory (Positive_Program), "positive",
         "positive directory");
      Landin.Testing.Check_Equal
        (Item, Class_Directory (Negative_Program), "negative",
         "negative directory");
      Landin.Testing.Check_Equal
        (Item, Class_Directory (Runtime), "runtime", "runtime directory");
      Landin.Testing.Check_Equal
        (Item, Class_Directory (Abi), "abi", "abi directory");
      Landin.Testing.Check_Equal
        (Item, Class_Directory (Debugger), "debugger", "debugger directory");
      Landin.Testing.Check_Equal
        (Item, Class_Directory (End_To_End), "end-to-end",
         "end to end directory");

      --  And every round trip, so a directory name and the class it names
      --  cannot drift apart.
      for Kind in Fixture_Class loop
         Named := Class_Of (Class_Directory (Kind), Found);
         Landin.Testing.Check
           (Item, Found, Class_Directory (Kind) & " is a known class");
         Landin.Testing.Check
           (Item, Named = Kind, Class_Directory (Kind) & " round trips");
      end loop;

      Named := Class_Of ("nonsense", Found);
      Landin.Testing.Check (Item, not Found, "an unknown class is refused");
      Landin.Testing.Check
        (Item, Named = Unit, "a refused class does not invent a value");
   end Classes_Have_Directories;

   procedure Well_Formed_Fixtures_Are_Discovered
     (Item : in out Landin.Testing.Context);

   procedure Well_Formed_Fixtures_Are_Discovered
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Found : Catalogue;
   begin
      Host.Add_Directory ("root");
      Host.Add_Directory ("root/unit");
      Host.Add_Directory ("root/unit/zebra");
      Host.Add_File
        ("root/unit/zebra/fixture.meta",
         "class: unit" & LF & "summary: later by name" & LF);
      Host.Add_Directory ("root/unit/alpha");
      Host.Add_File
        ("root/unit/alpha/fixture.meta",
         "# a comment" & LF & LF & "class: unit" & LF
         & "summary: earlier by name" & LF
         & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/negative");
      Host.Add_Directory ("root/negative/broken-name");
      Host.Add_File
        ("root/negative/broken-name/fixture.meta",
         "class: negative" & LF & "summary: a rejection" & LF
         & "program: broken.ldn" & LF & "expect: broken.expected" & LF
         & "args: broken.ldn" & LF & "status: 1" & LF);

      Discover (Found, "root", Host);

      Landin.Testing.Check_Equal
        (Item, Problem_Count (Found), 0,
         "well-formed fixtures have no problems");
      Landin.Testing.Check_Equal (Item, Count (Found), 3, "three fixtures");
      Landin.Testing.Check_Equal
        (Item, Count_Of (Found, Unit), 2, "two unit fixtures");
      Landin.Testing.Check_Equal
        (Item, Count_Of (Found, Negative_Program), 1, "one negative fixture");
      Landin.Testing.Check_Equal
        (Item, Name (Nth (Found, 1)), "alpha", "classes then names order");
      Landin.Testing.Check_Equal
        (Item, Name (Nth (Found, 2)), "zebra", "names are sorted");
      Landin.Testing.Check_Equal
        (Item, Name (Nth (Found, 3)), "broken-name",
         "a later class comes after an earlier one");
      Landin.Testing.Check_Equal
        (Item, Summary (Nth (Found, 1)), "earlier by name", "summary is kept");
      Landin.Testing.Check_Equal
        (Item, Targets (Nth (Found, 1)), "linux-x86-64", "targets are kept");
      Landin.Testing.Check_Equal
        (Item, Program (Nth (Found, 3)), "broken.ldn", "program is kept");
      Landin.Testing.Check_Equal
        (Item, Expect (Nth (Found, 3)), "broken.expected", "expect is kept");
   end Well_Formed_Fixtures_Are_Discovered;

   procedure Malformed_Metadata_Is_Refused
     (Item : in out Landin.Testing.Context);

   procedure Malformed_Metadata_Is_Refused
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Found : Catalogue;
   begin
      Host.Add_Directory ("root");
      Host.Add_Directory ("root/unit");

      Host.Add_Directory ("root/unit/no-metadata");

      Host.Add_Directory ("root/unit/unknown-key");
      Host.Add_File
        ("root/unit/unknown-key/fixture.meta",
         "class: unit" & LF & "summary: fine" & LF & "colour: blue" & LF);

      Host.Add_Directory ("root/unit/duplicate-key");
      Host.Add_File
        ("root/unit/duplicate-key/fixture.meta",
         "class: unit" & LF & "summary: one" & LF & "summary: two" & LF);

      Host.Add_Directory ("root/unit/missing-summary");
      Host.Add_File
        ("root/unit/missing-summary/fixture.meta", "class: unit" & LF);

      Host.Add_Directory ("root/unit/wrong-class");
      Host.Add_File
        ("root/unit/wrong-class/fixture.meta",
         "class: negative" & LF & "summary: mismatched" & LF);

      Host.Add_Directory ("root/unit/not-a-pair");
      Host.Add_File
        ("root/unit/not-a-pair/fixture.meta",
         "class: unit" & LF & "summary: fine" & LF & "nonsense" & LF);

      Host.Add_File ("root/unit/stray.txt", "not a fixture");

      Discover (Found, "root", Host);

      Landin.Testing.Check_Equal
        (Item, Count (Found), 0,
         "a fixture with any reported fault is not accepted");
      Landin.Testing.Check
        (Item, Mentions (Found, "metadata is missing or unreadable"),
         "a fixture without metadata is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "unknown key: colour"),
         "an unknown key is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "duplicate key: summary"),
         "a duplicate key is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "missing required key: summary"),
         "a missing required key is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "does not match directory"),
         "a class that disagrees with its directory is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "is not `key: value`"),
         "a malformed line is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "fixture entry is not a directory"),
         "a stray file in a class directory is reported");
   end Malformed_Metadata_Is_Refused;

   --  Reads the repository's real fixture tree, deliberately: the tree is
   --  the thing under test, and a fake copy of it would prove nothing
   --  about what is on disk.
   procedure Repository_Fixtures_Are_Clean
     (Item : in out Landin.Testing.Context);

   procedure Repository_Fixtures_Are_Clean
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Platform.Native.Native_Filesystem;
      Found : Catalogue;
   begin
      Discover (Found, Valid_Root, Host);

      Landin.Testing.Check
        (Item, Count (Found) > 0,
         "the repository's fixture tree contains fixtures");
      Landin.Testing.Check_Equal
        (Item, Problem_Count (Found), 0,
         "the repository's fixture tree has no metadata problems");
   end Repository_Fixtures_Are_Clean;

   procedure Repository_Malformed_Cases_Are_Refused
     (Item : in out Landin.Testing.Context);

   procedure Repository_Malformed_Cases_Are_Refused
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Platform.Native.Native_Filesystem;
      Found : Catalogue;

      procedure Reports (Case_Name : String; Fault : String);

      --  Naming the case as well as the fault is what makes a deleted or
      --  renamed case fail here, instead of quietly shrinking what the
      --  on-disk tree covers.
      procedure Reports (Case_Name : String; Fault : String) is
         Seen : Boolean := False;
      begin
         for Index in 1 .. Problem_Count (Found) loop
            declare
               Problem : constant String := Nth_Problem (Found, Index);
            begin
               if Ada.Strings.Fixed.Index (Problem, Case_Name) > 0
                 and then Ada.Strings.Fixed.Index (Problem, Fault) > 0
               then
                  Seen := True;
               end if;
            end;
         end loop;

         Landin.Testing.Check
           (Item, Seen, Case_Name & " is reported: " & Fault);
      end Reports;

   begin
      Discover (Found, Invalid_Root, Host);

      Landin.Testing.Check_Equal
        (Item, Count (Found), 0, "no malformed fixture is accepted");

      --  One per row of compiler/tests/harness-cases/README.md.
      Reports ("no-metadata", "metadata is missing or unreadable");
      Reports ("unknown-key", "unknown key: colour");
      Reports ("duplicate-key", "duplicate key: summary");
      Reports ("missing-summary", "missing required key: summary");
      Reports ("wrong-class", "does not match directory");
      Reports ("not-a-pair", "is not `key: value`");
      Reports ("unknown-target", "unknown target: vax-11-780");
      Reports ("stray.txt", "fixture entry is not a directory");

      --  Exact, so a new fault cannot be added to the tree without being
      --  named here, and an old one cannot vanish.
      Landin.Testing.Check_Equal
        (Item, Problem_Count (Found), 8,
         "the documented malformed cases are the reported ones");
   end Repository_Malformed_Cases_Are_Refused;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "fixtures", "classes have directories",
         Classes_Have_Directories'Access);
      Landin.Testing.Register
        (Into, "fixtures", "well formed fixtures are discovered",
         Well_Formed_Fixtures_Are_Discovered'Access);
      Landin.Testing.Register
        (Into, "fixtures", "malformed metadata is refused",
         Malformed_Metadata_Is_Refused'Access);
      Landin.Testing.Register
        (Into, "fixtures", "repository fixtures are clean",
         Repository_Fixtures_Are_Clean'Access);
      Landin.Testing.Register
        (Into, "fixtures", "repository malformed cases are refused",
         Repository_Malformed_Cases_Are_Refused'Access);
   end Register;

end Landin.Tests.Fixture_Suite;
