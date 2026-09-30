with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Diagnostics;
with Landin.Diagnostics.Suggestions;
with Landin.Driver;
with Landin.Platform;
with Landin.Platform.Native;
with Landin.Platform.Overlays;
with Landin.Source;
with Landin.Testing.Fakes;
with Landin.Testing.Fixes;
with Landin.Testing.Fixtures;

package body Landin.Tests.Fixes_Suite is

   package Diag renames Landin.Diagnostics;
   package Fixtures renames Landin.Testing.Fixtures;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Platform.Read_Status;

   Corpus : constant String := "../tests/fixtures";

   function Trimmed (Text : String) return String
     is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   --  The codes a report carries, whatever their level, in its order and
   --  spelled as a fixture's `codes:` spells them.
   function Codes_Of (Found : Diag.Diagnostic_List) return String;

   function Codes_Of (Found : Diag.Diagnostic_List) return String is
      Result : Unbounded.Unbounded_String;
   begin
      for Index in 1 .. Diag.Count (Found) loop
         if Index > 1 then
            Unbounded.Append (Result, ", ");
         end if;
         Unbounded.Append (Result, Diag.Code (Diag.Get (Found, Index)));
      end loop;
      return Unbounded.To_String (Result);
   end Codes_Of;

   --  Edits from two diagnostics are applied together, from the end of the
   --  text back, and an overlap between them is refused rather than
   --  guessed at.
   procedure Fixes_Apply_From_The_End
     (Item : in out Landin.Testing.Context);

   procedure Fixes_Apply_From_The_End
     (Item : in out Landin.Testing.Context)
   is
      Text  : constant String := "ab cd ef";
      Found : Diag.Diagnostic_List;
      Clash : Diag.Diagnostic_List;
      Clashed : Boolean;

      function Fixed_At
        (Where : Landin.Source.Span; Bytes : String) return Diag.Diagnostic;

      function Fixed_At
        (Where : Landin.Source.Span; Bytes : String) return Diag.Diagnostic
      is
         Report : Diag.Diagnostic := Diag.Make
           ("L0990", Diag.Error, 1, Where, "fixable");
         Made : Diag.Fix := Diag.Make_Fix
           (Diag.Repair'First, Diag.Likely, "fix");
      begin
         Diag.Add_Edit (Made, Diag.Make_Edit (1, Where, Bytes));
         Diag.Add_Fix (Report, Made);
         return Report;
      end Fixed_At;
   begin
      Found.Append (Fixed_At ((6, 8), "xyz"));
      Found.Append (Fixed_At ((0, 2), ""));
      Found.Append (Fixed_At ((3, 3), "+"));
      Landin.Testing.Check_Equal
        (Item, Landin.Testing.Fixes.Applied (Found, 1, Text, Clashed),
         " +cd xyz", "every edit lands at the offsets the source had");
      Landin.Testing.Check
        (Item, not Clashed, "edits that do not overlap do not clash");
      Landin.Testing.Check
        (Item, Landin.Testing.Fixes.Edits (Found, 1)
               and then not Landin.Testing.Fixes.Edits (Found, 2),
         "only the edited source is edited");

      Clash.Append (Fixed_At ((1, 4), "q"));
      Clash.Append (Fixed_At ((3, 5), "r"));
      Landin.Testing.Check_Equal
        (Item, Landin.Testing.Fixes.Applied (Clash, 1, Text, Clashed), Text,
         "overlapping fixes leave the text alone");
      Landin.Testing.Check
        (Item, Clashed, "and say that they clashed");
   end Fixes_Apply_From_The_End;

   --  Every fixture that pins a fix: its program is compiled, the first
   --  fix of every diagnostic that offers one is applied, the result must
   --  be the bytes the fixture records, and the result must then compile
   --  with nothing at all to report.  A one-file fixture runs on a fake
   --  filesystem holding its sources; reading those sources, the goldens
   --  and a rooted fixture's module closure from the real tree is this
   --  case's deliberate exception, as it is the parser suite's.
   procedure Every_Pinned_Fix_Compiles_Clean
     (Item : in out Landin.Testing.Context);

   procedure Every_Pinned_Fix_Compiles_Clean
     (Item : in out Landin.Testing.Context)
   is
      Real      : aliased Landin.Platform.Native.Native_Filesystem;
      Catalogue : Fixtures.Catalogue;
      Pinned    : Natural := 0;
      Expected  : Natural := 0;

      function Read (Path : String) return String;

      function Read (Path : String) return String is
         Content : Unbounded.Unbounded_String;
         Status  : Landin.Platform.Read_Status;
      begin
         Real.Read_File (Path, Content, Status);
         if Status /= Landin.Platform.Read_Ok then
            Landin.Testing.Fail (Item, Path & " is unreadable");
            return "";
         end if;
         return Unbounded.To_String (Content);
      end Read;

      procedure Run_One (Fixture : Fixtures.Fixture);

      procedure Run_One (Fixture : Fixtures.Fixture) is
         Label : constant String := Fixtures.Name (Fixture);
         Directory : constant String :=
           Corpus & "/" & Fixtures.Class_Directory
             (Fixtures.Class (Fixture)) & "/" & Label;
         Arguments : Landin.Platform.Path_List;
         Tools     : Landin.Testing.Fakes.Fake_Tool_Runner;
         Rooted    : constant Boolean := Fixtures.Module_Root (Fixture) /= "";

         --  Which golden file a source's result is, or "" for a source the
         --  fixture says nothing about.
         function Golden_For (Path : String) return String;

         function Golden_For (Path : String) return String is
            Written : constant String := Fixtures.Fixed (Fixture);
            First   : Integer := Written'First;
            Result  : Unbounded.Unbounded_String;

            procedure Consider (Pair : String);

            procedure Consider (Pair : String) is
               Arrow : constant Natural :=
                 Ada.Strings.Fixed.Index (Pair, "->");
            begin
               if Arrow = 0 then
                  if Path = Directory & "/" & Fixtures.Program (Fixture) then
                     Result := Unbounded.To_Unbounded_String (Trimmed (Pair));
                  end if;
               elsif Path = Directory & "/"
                 & Trimmed (Pair (Pair'First .. Arrow - 1))
               then
                  Result := Unbounded.To_Unbounded_String
                    (Trimmed (Pair (Arrow + 2 .. Pair'Last)));
               end if;
            end Consider;
         begin
            for Index in Written'First .. Written'Last + 1 loop
               if Index > Written'Last or else Written (Index) = ',' then
                  Consider (Written (First .. Index - 1));
                  First := Index + 1;
               end if;
            end loop;
            return Unbounded.To_String (Result);
         end Golden_For;

         procedure Check_Clean (Again : Landin.Driver.Outcome);

         procedure Check_Clean (Again : Landin.Driver.Outcome) is
         begin
            Landin.Testing.Check_Equal
              (Item, Again.Status, Landin.Driver.Status_Success,
               Label & ": the fixed program is accepted");
            Landin.Testing.Check_Equal
              (Item, Unbounded.To_String (Again.Report), "",
               Label & ": the fixed program reports nothing");
         end Check_Clean;
      begin
         Fixtures.Append_Module_Arguments (Fixture, Corpus, Arguments);

         declare
            First_Host : Landin.Platform.Overlays.Overlay (Real'Access);
            Fake_Host  : Landin.Testing.Fakes.Fake_Filesystem;
            Ran : Landin.Driver.Outcome;
         begin
            if Rooted then
               Ran := Landin.Driver.Execute (Arguments, First_Host, Tools);
            else
               for Path of Arguments loop
                  Fake_Host.Add_File (Path, Read (Path));
               end loop;
               Ran := Landin.Driver.Execute (Arguments, Fake_Host, Tools);
            end if;

            Landin.Testing.Check_Equal
              (Item, Codes_Of (Ran.Found),
               Fixtures.Normalized_Codes (Fixtures.Codes (Fixture)),
               Label & ": the report carries its pinned codes");

            --  A mistake can be reported more than once -- a misspelt
            --  argument label also leaves its parameter unfilled -- and
            --  only the report that names it can say how to repair it.
            --  That the fixes offered are enough is what compiling the
            --  result clean shows.
            Landin.Testing.Check
              (Item,
               (for some Index in 1 .. Diag.Count (Ran.Found) =>
                  Diag.Fix_Count (Diag.Get (Ran.Found, Index)) > 0),
               Label & ": the report offers a fix");

            declare
               Fixed_Host : Landin.Platform.Overlays.Overlay (Real'Access);
               Fixed_Fake : Landin.Testing.Fakes.Fake_Filesystem;
               Goldens    : Natural := 0;
            begin
               for Index in 1 .. Natural (Ran.Named.Length) loop
                  declare
                     Path   : constant String := Ran.Named.Element (Index);
                     Id     : constant Landin.Source.Source_Id :=
                       Landin.Source.Source_Id (Index);
                     Golden : constant String := Golden_For (Path);
                     Before : constant String := Read (Path);
                     Clashed : Boolean;
                     After  : constant String :=
                       Landin.Testing.Fixes.Applied
                         (Ran.Found, Id, Before, Clashed);
                  begin
                     Landin.Testing.Check
                       (Item, not Clashed,
                        Label & ": the fixes of " & Path & " do not clash");

                     if Golden /= "" then
                        Goldens := Goldens + 1;
                        Landin.Testing.Check_Equal
                          (Item, After, Read (Directory & "/" & Golden),
                           Label & ": " & Path & " becomes " & Golden);
                     else
                        Landin.Testing.Check
                          (Item,
                           not Landin.Testing.Fixes.Edits (Ran.Found, Id),
                           Label & ": " & Path & " is edited and the"
                           & " fixture records no result for it");
                     end if;

                     if Rooted then
                        Fixed_Host.Hold (Path, After);
                     else
                        Fixed_Fake.Add_File (Path, After);
                     end if;
                  end;
               end loop;

               Landin.Testing.Check
                 (Item, Goldens > 0,
                  Label & ": `fixed` names the result of a source the"
                  & " compilation read");

               if Rooted then
                  Check_Clean
                    (Landin.Driver.Execute (Arguments, Fixed_Host, Tools));
               else
                  Check_Clean
                    (Landin.Driver.Execute (Arguments, Fixed_Fake, Tools));
               end if;
            end;
         end;

         Pinned := Pinned + 1;
      end Run_One;
   begin
      Fixtures.Discover (Catalogue, Corpus, Real);
      Landin.Testing.Check_Equal
        (Item, Fixtures.Problem_Count (Catalogue), 0,
         "the corpus metadata is valid");
      if Fixtures.Problem_Count (Catalogue) /= 0 then
         return;
      end if;

      for Index in 1 .. Fixtures.Count (Catalogue) loop
         declare
            Fixture : constant Fixtures.Fixture :=
              Fixtures.Nth (Catalogue, Index);
         begin
            if Fixtures.Fixed (Fixture) /= "" then
               Expected := Expected + 1;
               Run_One (Fixture);
            end if;
         end;
      end loop;

      Landin.Testing.Check_Equal
        (Item, Pinned, Expected, "every fixture that pins a fix was run");
   end Every_Pinned_Fix_Compiles_Clean;

   --  [1860]'s nearness: the distance counts a swap of two neighbours as
   --  one edit, the bound is a third of the written name and never admits
   --  a name no longer than the distance, and the order is total.
   procedure Nearness_Is_Bounded_And_Ordered
     (Item : in out Landin.Testing.Context);

   procedure Nearness_Is_Bounded_And_Ordered
     (Item : in out Landin.Testing.Context)
   is
      package Near renames Landin.Diagnostics.Suggestions;
      Tied   : Near.Ranking;
      Nested : Near.Ranking;
      Many   : Near.Ranking;
   begin
      Landin.Testing.Check_Equal
        (Item, Near.Distance ("cuont", "count"), 1,
         "two swapped neighbours are one edit");
      Landin.Testing.Check_Equal
        (Item, Near.Distance ("limt", "limit"), 1, "a missing byte is one");
      Landin.Testing.Check_Equal
        (Item, Near.Distance ("abc", "xyz"), 3, "three replacements");
      Landin.Testing.Check_Equal
        (Item, Near.Distance ("", "ab"), 2, "from nothing");
      Landin.Testing.Check
        (Item, not Near.Near ("c", "b"),
         "a one-byte name is not a misspelling of another");
      Landin.Testing.Check
        (Item, not Near.Near ("abcde", "abxye"),
         "two edits in five bytes is past the bound");
      Landin.Testing.Check
        (Item, Near.Near ("abcdef", "abxyef"),
         "two edits in six bytes is inside it");
      Landin.Testing.Check
        (Item, not Near.Near ("same", "same"),
         "a name is never its own suggestion");

      Near.Consider (Tied, "tota", "totb", Depth => 0);
      Near.Consider (Tied, "tota", "total", Depth => 1);
      Near.Consider (Tied, "tota", "iota", Depth => 0);
      Near.Consider (Tied, "tota", "toto", Depth => 1);
      Landin.Testing.Check_Equal
        (Item, Near.Count (Tied), 3, "at most three, all at one distance");
      Landin.Testing.Check
        (Item,
         Near.Nth (Tied, 1) = "iota" and then Near.Nth (Tied, 2) = "totb"
           and then Near.Nth (Tied, 3) = "total",
         "innermost first, then by spelling");

      Near.Consider (Nested, "vlaue", "values", Depth => 0);
      Near.Consider (Nested, "vlaue", "value", Depth => 2);
      Landin.Testing.Check
        (Item, Near.Count (Nested) = 1 and then Near.Nth (Nested, 1) = "value",
         "a nearer name wins over an inner one, and farther ones go");

      Near.Consider (Many, "item", "items", Depth => 3);
      Near.Consider (Many, "item", "items", Depth => 1);
      Near.Consider (Many, "item", "itex", Depth => 2);
      Landin.Testing.Check
        (Item, Near.Count (Many) = 2 and then Near.Nth (Many, 1) = "items",
         "a spelling offered twice keeps its innermost depth once");
   end Nearness_Is_Bounded_And_Ordered;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "fixes", "nearness is bounded and ordered",
         Nearness_Is_Bounded_And_Ordered'Access);
      Landin.Testing.Register
        (Into, "fixes", "fixes apply from the end",
         Fixes_Apply_From_The_End'Access);
      Landin.Testing.Register
        (Into, "fixes", "every pinned fix compiles clean",
         Every_Pinned_Fix_Compiles_Clean'Access);
   end Register;

end Landin.Tests.Fixes_Suite;
