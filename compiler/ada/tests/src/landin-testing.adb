with Ada.Exceptions;

package body Landin.Testing is

   use type Unbounded.Unbounded_String;

   LF : constant Character := Character'Val (10);

   procedure Note (Item : in out Context; Description : String);

   procedure Note (Item : in out Context; Description : String) is
   begin
      Item.Failures := Item.Failures + 1;
      Unbounded.Append (Item.Text, "      " & Description & LF);
   end Note;

   procedure Check
     (Item : in out Context; Condition : Boolean; Description : String)
   is
   begin
      Item.Checks := Item.Checks + 1;
      if not Condition then
         Note (Item, "failed: " & Description);
      end if;
   end Check;

   procedure Check_Equal
     (Item : in out Context; Actual, Expected : String; Description : String)
   is
   begin
      Item.Checks := Item.Checks + 1;
      if Actual /= Expected then
         Note
           (Item,
            "failed: " & Description & LF
            & "        expected: " & Expected & LF
            & "        actual:   " & Actual);
      end if;
   end Check_Equal;

   procedure Check_Equal
     (Item : in out Context; Actual, Expected : Integer; Description : String)
   is
   begin
      Item.Checks := Item.Checks + 1;
      if Actual /= Expected then
         Note
           (Item,
            "failed: " & Description
            & " (expected" & Integer'Image (Expected)
            & ", actual" & Integer'Image (Actual) & ")");
      end if;
   end Check_Equal;

   procedure Fail (Item : in out Context; Description : String) is
   begin
      Item.Checks := Item.Checks + 1;
      Note (Item, "failed: " & Description);
   end Fail;

   function Checks (Item : Context) return Natural is (Item.Checks);

   function Failures (Item : Context) return Natural is (Item.Failures);

   function Failure_Text (Item : Context) return String
     is (Unbounded.To_String (Item.Text));

   function Is_Registered
     (In_Registry : Registry; Suite : String; Name : String) return Boolean
   is
   begin
      for Item of In_Registry.Items loop
         if Unbounded.To_String (Item.Suite) = Suite
           and then Unbounded.To_String (Item.Name) = Name
         then
            return True;
         end if;
      end loop;
      return False;
   end Is_Registered;

   procedure Register
     (Into  : in out Registry;
      Suite : String;
      Name  : String;
      Run   : not null Case_Body)
   is
   begin
      if Is_Registered (Into, Suite, Name) then
         raise Compiler_Defect
           with "duplicate test case: " & Suite & "/" & Name;
      end if;

      Into.Items.Append
        (Entry_Record'
           (Suite => Unbounded.To_Unbounded_String (Suite),
            Name  => Unbounded.To_Unbounded_String (Name),
            Run   => Run));
   end Register;

   function Has_Suite (In_Registry : Registry; Suite : String) return Boolean
   is
   begin
      for Item of In_Registry.Items loop
         if Unbounded.To_String (Item.Suite) = Suite then
            return True;
         end if;
      end loop;
      return False;
   end Has_Suite;

   function Case_Count (In_Registry : Registry) return Natural
     is (Natural (In_Registry.Items.Length));

   function Precedes (Left, Right : Entry_Record) return Boolean;

   function Precedes (Left, Right : Entry_Record) return Boolean is
      Left_Suite  : constant String := Unbounded.To_String (Left.Suite);
      Right_Suite : constant String := Unbounded.To_String (Right.Suite);
   begin
      if Left_Suite /= Right_Suite then
         return Left_Suite < Right_Suite;
      end if;
      return Unbounded.To_String (Left.Name)
             < Unbounded.To_String (Right.Name);
   end Precedes;

   package Sorting is new Entry_Vectors.Generic_Sorting ("<" => Precedes);

   procedure Run
     (In_Registry : Registry;
      Transcript  : out Ada.Strings.Unbounded.Unbounded_String;
      Result      : out Summary)
   is
      Ordered : Entry_Vectors.Vector := In_Registry.Items;
      Current : Unbounded.Unbounded_String;
   begin
      Transcript := Unbounded.Null_Unbounded_String;
      Result := (others => 0);
      Sorting.Sort (Ordered);

      for Item of Ordered loop
         if Item.Suite /= Current then
            Current := Item.Suite;
            Unbounded.Append
              (Transcript, Unbounded.To_String (Current) & LF);
         end if;

         declare
            State : Context;
            Label : constant String := Unbounded.To_String (Item.Name);
         begin
            --  A case that raises is a case that failed, not a run that
            --  stopped.  Letting it propagate loses every case after it,
            --  and the transcript then says nothing about either.
            begin
               Item.Run.all (State);
            exception
               when Error : others =>
                  Note
                    (State,
                     "raised " & Ada.Exceptions.Exception_Name (Error)
                     & ": " & Ada.Exceptions.Exception_Message (Error));
            end;

            Result.Cases  := Result.Cases + 1;
            Result.Checks := Result.Checks + Checks (State);

            if Failures (State) = 0 then
               Result.Passed := Result.Passed + 1;
               Unbounded.Append (Transcript, "  pass  " & Label & LF);
            else
               Result.Failed := Result.Failed + 1;
               Unbounded.Append (Transcript, "  FAIL  " & Label & LF);
               Unbounded.Append (Transcript, Failure_Text (State));
            end if;
         end;
      end loop;

      Unbounded.Append
        (Transcript,
         LF & "cases" & Natural'Image (Result.Cases)
         & ", passed" & Natural'Image (Result.Passed)
         & ", failed" & Natural'Image (Result.Failed)
         & ", checks" & Natural'Image (Result.Checks) & LF);
   end Run;

end Landin.Testing;
