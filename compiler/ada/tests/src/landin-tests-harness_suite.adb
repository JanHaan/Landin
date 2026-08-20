with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

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

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
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
        (Into, "harness", "assertions can fail",
         Assertions_Can_Fail'Access);
      Landin.Testing.Register
        (Into, "harness", "raising cases fail alone",
         Raising_Cases_Fail_Alone'Access);
   end Register;

end Landin.Tests.Harness_Suite;
