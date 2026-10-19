with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Tests.Fixture_Execution_Suite;

package body Landin.Tests.Harness_Suite is

   package Unbounded renames Ada.Strings.Unbounded;

   function Contains (Text : String; Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   --  Cases used as material by the harness's own tests.  They are
   --  registered into throwaway registries, never into the real one.
   procedure Always_Passes (Item : in out Landin.Testing.Context);
   procedure Always_Fails (Item : in out Landin.Testing.Context);

   procedure Always_Passes (Item : in out Landin.Testing.Context) is
   begin
      Landin.Testing.Check (Item, True, "true is true");
   end Always_Passes;

   procedure Always_Fails (Item : in out Landin.Testing.Context) is
   begin
      Landin.Testing.Fail (Item, "this case is meant to fail");
   end Always_Fails;

   --  Material for the shard test: how many times each item of a divided
   --  case's work was taken, over every run since it was last cleared.
   Shared_Items : array (0 .. 9) of Natural := [others => 0];

   procedure Takes_Its_Share (Item : in out Landin.Testing.Context);

   procedure Takes_Its_Share (Item : in out Landin.Testing.Context) is
   begin
      for Ordinal in Shared_Items'Range loop
         if Landin.Testing.In_Share (Ordinal) then
            Shared_Items (Ordinal) := Shared_Items (Ordinal) + 1;
         end if;
      end loop;
      Landin.Testing.Check (Item, True, "the share was taken");
   end Takes_Its_Share;

   --  The gate runs the inventory as shards on separate runners and
   --  requires every one, so the shards have to be the complete run
   --  between them: each ordinary case in exactly one, a divided case in
   --  all of them over disjoint shares that cover its work.
   procedure Shards_Partition_The_Inventory
     (Item : in out Landin.Testing.Context);

   procedure Shards_Partition_The_Inventory
     (Item : in out Landin.Testing.Context)
   is
      LF      : constant Character := Character'Val (10);
      Names   : constant array (1 .. 7) of String (1 .. 1) :=
        ["a", "b", "c", "d", "e", "f", "g"];
      Seen    : array (Names'Range) of Natural := [others => 0];
      Scratch : Landin.Testing.Registry;
      Split   : Natural := 0;
      Ran     : Natural := 0;
   begin
      for Name of Names loop
         Landin.Testing.Register
           (Scratch, "sample", Name, Always_Passes'Access);
      end loop;
      Landin.Testing.Register
        (Scratch, "sample", "split", Takes_Its_Share'Access,
         Divided => True);
      Shared_Items := [others => 0];

      for Index in 1 .. 3 loop
         declare
            Transcript : Unbounded.Unbounded_String;
            Result     : Landin.Testing.Summary;
         begin
            Landin.Testing.Run
              (Scratch, (Index => Index, Count => 3), Transcript, Result);

            declare
               Text : constant String := Unbounded.To_String (Transcript);
               Head : constant String :=
                 "SHARD" & Positive'Image (Index) & " of 3" & LF;
            begin
               Landin.Testing.Check
                 (Item, Text'Length >= Head'Length
                    and then Text (Text'First .. Text'First + Head'Length - 1)
                             = Head,
                  "a shard's transcript says which shard it is");
               for Number in Names'Range loop
                  if Contains (Text, "pass  " & Names (Number) & LF) then
                     Seen (Number) := Seen (Number) + 1;
                  end if;
               end loop;
               if Contains (Text, "pass  split" & LF) then
                  Split := Split + 1;
               end if;
            end;
            Ran := Ran + Result.Cases;
            Landin.Testing.Check_Equal
              (Item, Result.Failed, 0, "a shard's cases pass");
         end;
      end loop;

      Landin.Testing.Check
        (Item, (for all Count of Seen => Count = 1),
         "every ordinary case ran in exactly one shard");
      Landin.Testing.Check_Equal
        (Item, Split, 3, "the divided case ran in every shard");
      Landin.Testing.Check
        (Item, (for all Count of Shared_Items => Count = 1),
         "every item of divided work ran exactly once");
      Landin.Testing.Check_Equal
        (Item, Ran, Names'Length + 3, "the shards ran nothing twice");
      Landin.Testing.Check
        (Item, (for all Ordinal in Shared_Items'Range =>
                  Landin.Testing.In_Share (Ordinal)),
         "outside a divided case every item is owned");

      declare
         Transcript : Unbounded.Unbounded_String;
         Result     : Landin.Testing.Summary;
      begin
         Shared_Items := [others => 0];
         Landin.Testing.Run
           (Scratch, Landin.Testing.Whole, Transcript, Result);
         Landin.Testing.Check
           (Item, not Contains (Unbounded.To_String (Transcript), "SHARD"),
            "the whole run does not call itself a shard");
         Landin.Testing.Check
           (Item, Result.Cases = Names'Length + 1
              and then (for all Count of Shared_Items => Count = 1),
            "the whole run takes every case and every item once");
      end;
   end Shards_Partition_The_Inventory;

   procedure Duplicate_Names_Are_Refused
     (Item : in out Landin.Testing.Context);

   procedure Duplicate_Names_Are_Refused
     (Item : in out Landin.Testing.Context)
   is
      Scratch : Landin.Testing.Registry;
   begin
      Landin.Testing.Register
        (Scratch, "sample", "one", Always_Passes'Access);
      Landin.Testing.Check
        (Item, Landin.Testing.Is_Registered (Scratch, "sample", "one"),
         "the case registered");

      Landin.Testing.Register
        (Scratch, "sample", "one", Always_Passes'Access);
      Landin.Testing.Fail (Item, "a duplicate name should be refused");
   exception
      when Landin.Compiler_Defect =>
         Landin.Testing.Check
           (Item, Landin.Testing.Case_Count (Scratch) = 1,
            "a duplicate name is refused and not counted");
   end Duplicate_Names_Are_Refused;

   procedure Suite_Inventory_Counts_Names
     (Item : in out Landin.Testing.Context);

   procedure Suite_Inventory_Counts_Names
     (Item : in out Landin.Testing.Context)
   is
      Scratch : Landin.Testing.Registry;
      Refused : Boolean := False;
   begin
      Landin.Testing.Check_Equal
        (Item, Landin.Testing.Suite_Count (Scratch), 0,
         "an empty registry has no suites");
      Landin.Testing.Register (Scratch, "beta", "one", Always_Passes'Access);
      Landin.Testing.Check_Equal
        (Item, Landin.Testing.Suite_Count (Scratch), 1,
         "one registered suite is counted");
      Landin.Testing.Register (Scratch, "alpha", "one", Always_Passes'Access);
      Landin.Testing.Register (Scratch, "beta", "two", Always_Passes'Access);
      Landin.Testing.Check_Equal
        (Item, Landin.Testing.Suite_Count (Scratch), 2,
         "nonadjacent names count suites rather than cases");
      Landin.Testing.Check_Equal
        (Item, Landin.Testing.Case_Count (Scratch), 3,
         "the three cases remain independently registered");
      Landin.Testing.Check
        (Item, Landin.Testing.Has_Suite (Scratch, "alpha")
           and then Landin.Testing.Has_Suite (Scratch, "beta")
           and then not Landin.Testing.Has_Suite (Scratch, "one"),
         "suite presence distinguishes suite names from case names");
      begin
         Landin.Testing.Register
           (Scratch, "alpha", "one", Always_Passes'Access);
      exception
         when Landin.Compiler_Defect => Refused := True;
      end;
      Landin.Testing.Check (Item, Refused, "duplicate case remains refused");
      Landin.Testing.Check_Equal
        (Item, Landin.Testing.Suite_Count (Scratch), 2,
         "a refused duplicate cannot alter the inventory");
   end Suite_Inventory_Counts_Names;

   procedure Order_Is_Deterministic (Item : in out Landin.Testing.Context);

   procedure Order_Is_Deterministic (Item : in out Landin.Testing.Context) is
      Forward    : Landin.Testing.Registry;
      Backward   : Landin.Testing.Registry;
      Left_Text  : Unbounded.Unbounded_String;
      Right_Text : Unbounded.Unbounded_String;
      Left       : Landin.Testing.Summary;
      Right      : Landin.Testing.Summary;
   begin
      Landin.Testing.Register (Forward, "beta", "b", Always_Passes'Access);
      Landin.Testing.Register (Forward, "alpha", "z", Always_Passes'Access);
      Landin.Testing.Register (Forward, "alpha", "a", Always_Passes'Access);

      Landin.Testing.Register (Backward, "alpha", "a", Always_Passes'Access);
      Landin.Testing.Register (Backward, "beta", "b", Always_Passes'Access);
      Landin.Testing.Register (Backward, "alpha", "z", Always_Passes'Access);

      Landin.Testing.Run (Forward, Left_Text, Left);
      Landin.Testing.Run (Backward, Right_Text, Right);

      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Left_Text),
         Unbounded.To_String (Right_Text),
         "registration order does not change the transcript");
      Landin.Testing.Check_Equal (Item, Left.Cases, 3, "three cases ran");
      Landin.Testing.Check_Equal (Item, Left.Failed, 0, "none failed");
   end Order_Is_Deterministic;

   procedure Failures_Are_Counted (Item : in out Landin.Testing.Context);

   procedure Filters_Select_Exact_Cases
     (Item : in out Landin.Testing.Context);

   procedure Filters_Select_Exact_Cases
     (Item : in out Landin.Testing.Context)
   is
      Scratch    : Landin.Testing.Registry;
      Transcript : Unbounded.Unbounded_String;
      Result     : Landin.Testing.Summary;
   begin
      Landin.Testing.Register
        (Scratch, "alpha", "one", Always_Passes'Access);
      Landin.Testing.Register
        (Scratch, "alpha", "two", Always_Passes'Access);
      Landin.Testing.Register
        (Scratch, "beta", "one", Always_Passes'Access);

      Landin.Testing.Run
        (Scratch, "alpha", "two", Transcript, Result);

      Landin.Testing.Check_Equal
        (Item, Result.Cases, 1, "one exact case ran");
      Landin.Testing.Check
        (Item, Contains (Unbounded.To_String (Transcript), "FILTERED"),
         "the transcript labels a focused run");
      Landin.Testing.Check
        (Item, Contains (Unbounded.To_String (Transcript), "pass  two"),
         "the selected case is in the transcript");
      Landin.Testing.Check
        (Item, not Contains (Unbounded.To_String (Transcript), "beta"),
         "another suite is absent");

      Landin.Testing.Run
        (Scratch, "missing", "", Transcript, Result);
      Landin.Testing.Check_Equal
        (Item, Result.Cases, 0, "an unknown filter runs nothing");
   end Filters_Select_Exact_Cases;

   procedure Failures_Are_Counted (Item : in out Landin.Testing.Context) is
      Scratch    : Landin.Testing.Registry;
      Transcript : Unbounded.Unbounded_String;
      Result     : Landin.Testing.Summary;
   begin
      Landin.Testing.Register (Scratch, "sample", "good",
                               Always_Passes'Access);
      Landin.Testing.Register (Scratch, "sample", "bad", Always_Fails'Access);
      Landin.Testing.Run (Scratch, Transcript, Result);

      Landin.Testing.Check_Equal (Item, Result.Cases, 2, "two cases ran");
      Landin.Testing.Check_Equal (Item, Result.Passed, 1, "one passed");
      Landin.Testing.Check_Equal (Item, Result.Failed, 1, "one failed");
      Landin.Testing.Check
        (Item,
         Unbounded.Index (Transcript, "this case is meant to fail") > 0,
         "the failure reason is in the transcript");
   end Failures_Are_Counted;

   --  The failing path of the assertions themselves.  Every other case in
   --  the repository takes only their passing path, so a Check or a
   --  Check_Equal that had stopped reporting would leave the whole run
   --  green while checking nothing.  The expectations here go through Fail,
   --  never through Check, so this case cannot be neutered by the same
   --  mutation it is watching for.
   procedure Assertions_Can_Fail (Item : in out Landin.Testing.Context);

   procedure Assertions_Can_Fail (Item : in out Landin.Testing.Context) is
      State : Landin.Testing.Context;
   begin
      Landin.Testing.Check (State, False, "a false condition");

      if Landin.Testing.Failures (State) /= 1 then
         Landin.Testing.Fail (Item, "Check did not report a false condition");
      end if;

      Landin.Testing.Check_Equal (State, "left", "right", "unequal strings");

      if Landin.Testing.Failures (State) /= 2 then
         Landin.Testing.Fail (Item, "Check_Equal accepted unequal strings");
      end if;

      Landin.Testing.Check_Equal (State, 1, 2, "unequal numbers");

      if Landin.Testing.Failures (State) /= 3 then
         Landin.Testing.Fail (Item, "Check_Equal accepted unequal numbers");
      end if;

      if Landin.Testing.Checks (State) /= 3 then
         Landin.Testing.Fail (Item, "checks were not counted");
      end if;

      Landin.Testing.Check (State, True, "a true condition");

      if Landin.Testing.Failures (State) /= 3 then
         Landin.Testing.Fail (Item, "Check reported a true condition");
      end if;

      if not Contains (Landin.Testing.Failure_Text (State), "unequal strings")
      then
         Landin.Testing.Fail (Item, "the failure text lost its description");
      end if;

      Landin.Testing.Check
        (Item, True, "the assertions report what they are given");
   end Assertions_Can_Fail;

   procedure Always_Raises (Item : in out Landin.Testing.Context);

   procedure Always_Raises (Item : in out Landin.Testing.Context) is
   begin
      Landin.Testing.Check (Item, True, "before the exception");
      raise Landin.Compiler_Defect with "a case that raises";
   end Always_Raises;

   --  A case that raises must fail, and the cases after it must still run.
   --  Letting the exception out loses the rest of the transcript, which is
   --  how one defect hides forty.
   procedure Raising_Cases_Fail_Alone
     (Item : in out Landin.Testing.Context);

   procedure Raising_Cases_Fail_Alone
     (Item : in out Landin.Testing.Context)
   is
      Scratch    : Landin.Testing.Registry;
      Transcript : Unbounded.Unbounded_String;
      Result     : Landin.Testing.Summary;
   begin
      Landin.Testing.Register (Scratch, "sample", "a-raises",
                               Always_Raises'Access);
      Landin.Testing.Register (Scratch, "sample", "b-passes",
                               Always_Passes'Access);

      Landin.Testing.Run (Scratch, Transcript, Result);

      Landin.Testing.Check_Equal (Item, Result.Cases, 2, "both cases ran");
      Landin.Testing.Check_Equal
        (Item, Result.Failed, 1, "only the raising case failed");
      Landin.Testing.Check_Equal
        (Item, Result.Passed, 1, "the case after it still ran");
      Landin.Testing.Check
        (Item,
         Contains (Unbounded.To_String (Transcript), "a case that raises"),
         "the exception message is in the transcript");
      Landin.Testing.Check
        (Item,
         Contains (Unbounded.To_String (Transcript), "COMPILER_DEFECT"),
         "the exception name is in the transcript");
   end Raising_Cases_Fail_Alone;

   procedure Host_Scope_Is_Explicit (Item : in out Landin.Testing.Context);

   procedure Host_Scope_Is_Explicit (Item : in out Landin.Testing.Context) is
      Complete : Landin.Testing.Registry;
      Host     : Landin.Testing.Registry;
   begin
      Landin.Tests.Fixture_Execution_Suite.Register (Complete);
      Landin.Tests.Fixture_Execution_Suite.Register
        (Host, Include_Target_Workloads => False);
      Landin.Testing.Check_Equal
        (Item, Landin.Testing.Case_Count (Complete),
         Landin.Testing.Case_Count (Host) + 3,
         "host scope excludes the three target workload cases");
      Landin.Testing.Check
        (Item, Landin.Testing.Is_Registered
           (Complete, "fixture execution", "hosted library links and runs")
         and then not Landin.Testing.Is_Registered
           (Host, "fixture execution", "hosted library links and runs"),
         "host scope excludes native linked library execution");
      Landin.Testing.Check
        (Item, Landin.Testing.Is_Registered
           (Complete, "fixture execution", "runtime fixtures execute")
         and then not Landin.Testing.Is_Registered
           (Host, "fixture execution", "runtime fixtures execute"),
         "the default retains runtime and ABI execution");
      Landin.Testing.Check
        (Item, not Landin.Testing.Is_Registered
           (Host, "fixture execution", "every positive fixture is emitted")
         and then Landin.Testing.Is_Registered
           (Host, "fixture execution", "recorded expectations hold"),
         "host scope retains diagnostics without target workload emission");
   end Host_Scope_Is_Explicit;

   --  Material for the progress test: what the run reported, one line
   --  per suite in the order it was told.
   Reported : Unbounded.Unbounded_String;

   procedure Note_Progress
     (Suite : String; Cases, Failed : Natural; Seconds : Duration);

   procedure Note_Progress
     (Suite : String; Cases, Failed : Natural; Seconds : Duration) is
   begin
      Unbounded.Append
        (Reported,
         Suite & Natural'Image (Cases) & Natural'Image (Failed)
         & (if Seconds >= 0.0 then " timed" else " untimed")
         & Character'Val (10));
   end Note_Progress;

   --  An unfiltered run of half an hour printed nothing until it ended, so
   --  a stuck run looked like a slow one.  Each suite now reports as it
   --  ends, with its cases, its failures and its duration, and only once.
   procedure Progress_Reports_Each_Suite
     (Item : in out Landin.Testing.Context);

   procedure Progress_Reports_Each_Suite
     (Item : in out Landin.Testing.Context)
   is
      LF         : constant Character := Character'Val (10);
      Scratch    : Landin.Testing.Registry;
      Transcript : Unbounded.Unbounded_String;
      Result     : Landin.Testing.Summary;
      Plain      : Unbounded.Unbounded_String;
      Unreported : Landin.Testing.Summary;
      Reporting  : Unbounded.Unbounded_String;
   begin
      Landin.Testing.Register (Scratch, "beta", "one", Always_Passes'Access);
      Landin.Testing.Register (Scratch, "alpha", "one", Always_Passes'Access);
      Landin.Testing.Register (Scratch, "alpha", "two", Always_Fails'Access);
      Landin.Testing.Register (Scratch, "alpha", "three",
                               Always_Passes'Access);

      Reported := Unbounded.Null_Unbounded_String;
      Landin.Testing.Run
        (Scratch, Transcript, Result, Progress => Note_Progress'Access);
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Reported),
         "alpha 3 1 timed" & LF & "beta 1 0 timed" & LF,
         "each suite reports once as it ends, with its cases and failures");
      Reporting := Transcript;

      Reported := Unbounded.Null_Unbounded_String;
      Landin.Testing.Run
        (Scratch, "beta", "", Transcript, Result,
         Progress => Note_Progress'Access);
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Reported), "beta 1 0 timed" & LF,
         "a filtered run reports only the suite it ran");

      Landin.Testing.Run (Scratch, Plain, Unreported);
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Reporting), Unbounded.To_String (Plain),
         "progress stays out of the transcript");
      Landin.Testing.Check_Equal
        (Item,
         Landin.Testing.Progress_Line ("lexer", 42, 1, 3.25),
         "progress: lexer: 42 cases, 1 failed, 3.2s",
         "the line names the suite, its cases, failures and seconds");
   end Progress_Reports_Each_Suite;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "harness", "progress reports each suite",
         Progress_Reports_Each_Suite'Access);
      Landin.Testing.Register
        (Into, "harness", "suite inventory counts names",
         Suite_Inventory_Counts_Names'Access);
      Landin.Testing.Register
        (Into, "harness", "host scope is explicit",
         Host_Scope_Is_Explicit'Access);
      Landin.Testing.Register
        (Into, "harness", "duplicate names are refused",
         Duplicate_Names_Are_Refused'Access);
      Landin.Testing.Register
        (Into, "harness", "order is deterministic",
         Order_Is_Deterministic'Access);
      Landin.Testing.Register
        (Into, "harness", "failures are counted",
         Failures_Are_Counted'Access);
      Landin.Testing.Register
        (Into, "harness", "filters select exact cases",
         Filters_Select_Exact_Cases'Access);
      Landin.Testing.Register
        (Into, "harness", "assertions can fail",
         Assertions_Can_Fail'Access);
      Landin.Testing.Register
        (Into, "harness", "raising cases fail alone",
         Raising_Cases_Fail_Alone'Access);
      Landin.Testing.Register
        (Into, "harness", "shards partition the inventory",
         Shards_Partition_The_Inventory'Access);
   end Register;

end Landin.Tests.Harness_Suite;
