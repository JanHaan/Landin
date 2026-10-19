with Ada.Calendar;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Exceptions;
with Ada.Text_IO;

package body Landin.Testing is

   use type Unbounded.Unbounded_String;

   LF : constant Character := Character'Val (10);

   Recorded : Timing_Vectors.Vector;

   --  The shard whose share the running case takes: the run's own for a
   --  Divided case, Whole for any other and outside a run.
   Current : Shard := Whole;

   function In_Share (Ordinal : Natural) return Boolean
     is (Owns (Current, Ordinal));

   function Last_Timings return Timing_Vectors.Vector is (Recorded);

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

   procedure Absorb (Into : in out Context; From : Context) is
   begin
      Into.Checks := Into.Checks + From.Checks;
      Into.Failures := Into.Failures + From.Failures;
      Unbounded.Append (Into.Text, From.Text);
   end Absorb;

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
     (Into    : in out Registry;
      Suite   : String;
      Name    : String;
      Run     : not null Case_Body;
      Divided : Boolean := False)
   is
   begin
      if Is_Registered (Into, Suite, Name) then
         raise Compiler_Defect
           with "duplicate test case: " & Suite & "/" & Name;
      end if;

      Into.Items.Append
        (Entry_Record'
           (Suite   => Unbounded.To_Unbounded_String (Suite),
            Name    => Unbounded.To_Unbounded_String (Name),
            Run     => Run,
            Divided => Divided));
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

   function Suite_Count (In_Registry : Registry) return Natural is
      package Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);
      Names : Sets.Set;
   begin
      for Item of In_Registry.Items loop
         Names.Include (Unbounded.To_String (Item.Suite));
      end loop;
      return Natural (Names.Length);
   end Suite_Count;

   function Case_Count (In_Registry : Registry) return Natural
     is (Natural (In_Registry.Items.Length));

   function Progress_Line
     (Suite : String; Cases, Failed : Natural; Seconds : Duration)
      return String
   is
      Tenths : constant Natural :=
        Natural (Float'Floor (Float (Duration'Max (Seconds, 0.0)) * 10.0));
      Whole  : constant String := Natural'Image (Tenths / 10);
      Part   : constant String := Natural'Image (Tenths mod 10);
   begin
      return "progress: " & Suite & ":" & Natural'Image (Cases) & " cases,"
        & Natural'Image (Failed) & " failed, "
        & Whole (Whole'First + 1 .. Whole'Last) & "."
        & Part (Part'First + 1 .. Part'Last) & "s";
   end Progress_Line;

   procedure Write_Progress
     (Suite : String; Cases, Failed : Natural; Seconds : Duration) is
   begin
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Progress_Line (Suite, Cases, Failed, Seconds));
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
   end Write_Progress;

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

   procedure Run_Selected
     (In_Registry  : Registry;
      Suite_Filter : String;
      Case_Filter  : String;
      Of_Shard     : Shard;
      Transcript   : out Ada.Strings.Unbounded.Unbounded_String;
      Result       : out Summary;
      Record_Timings : Boolean;
      Progress       : Progress_Report);

   procedure Run
     (In_Registry : Registry;
      Transcript  : out Ada.Strings.Unbounded.Unbounded_String;
      Result      : out Summary;
      Record_Timings : Boolean := False;
      Progress       : Progress_Report := null)
   is
   begin
      Run_Selected
        (In_Registry, "", "", Whole, Transcript, Result, Record_Timings,
         Progress);
   end Run;

   procedure Run
     (In_Registry : Registry;
      Of_Shard    : Shard;
      Transcript  : out Ada.Strings.Unbounded.Unbounded_String;
      Result      : out Summary;
      Record_Timings : Boolean := False;
      Progress       : Progress_Report := null)
   is
   begin
      Run_Selected
        (In_Registry, "", "", Of_Shard, Transcript, Result, Record_Timings,
         Progress);
   end Run;

   procedure Run
     (In_Registry : Registry;
      Suite_Filter : String;
      Case_Filter  : String;
      Transcript   : out Ada.Strings.Unbounded.Unbounded_String;
      Result       : out Summary;
      Record_Timings : Boolean := False;
      Progress       : Progress_Report := null)
   is
   begin
      Run_Selected
        (In_Registry, Suite_Filter, Case_Filter, Whole, Transcript, Result,
         Record_Timings, Progress);
   end Run;

   procedure Run_Selected
     (In_Registry  : Registry;
      Suite_Filter : String;
      Case_Filter  : String;
      Of_Shard     : Shard;
      Transcript   : out Ada.Strings.Unbounded.Unbounded_String;
      Result       : out Summary;
      Record_Timings : Boolean;
      Progress       : Progress_Report)
   is
      Ordered : Entry_Vectors.Vector := In_Registry.Items;
      Heading : Unbounded.Unbounded_String;
      --  Each ordinary case's place among the ordinary cases, counted in
      --  the sorted order every shard sees, decides which shard owns it.
      Ordinal : Natural := 0;
      Owned   : Boolean;
      --  The suite now running, for Progress: its cases, failures and the
      --  time it started.
      Suite_Cases  : Natural := 0;
      Suite_Failed : Natural := 0;
      Suite_Began  : Ada.Calendar.Time := Ada.Calendar.Clock;

      procedure Suite_Ended;

      procedure Suite_Ended is
      begin
         if Progress /= null and then Suite_Cases > 0 then
            Progress
              (Unbounded.To_String (Heading), Suite_Cases, Suite_Failed,
               Ada.Calendar."-" (Ada.Calendar.Clock, Suite_Began));
         end if;
         Suite_Cases := 0;
         Suite_Failed := 0;
         Suite_Began := Ada.Calendar.Clock;
      end Suite_Ended;

      function Matches (Item : Entry_Record) return Boolean;

      function Matches (Item : Entry_Record) return Boolean is
        ((Suite_Filter = ""
          or else Unbounded.To_String (Item.Suite) = Suite_Filter)
         and then
           (Case_Filter = ""
            or else Unbounded.To_String (Item.Name) = Case_Filter));
   begin
      Transcript := Unbounded.Null_Unbounded_String;
      Result := (others => 0);
      if Record_Timings then
         Recorded.Clear;
      end if;
      Sorting.Sort (Ordered);

      if Suite_Filter /= "" then
         Unbounded.Append
           (Transcript,
            "FILTERED suite=" & Suite_Filter
            & (if Case_Filter = "" then ""
               else " case=" & Case_Filter)
            & LF & LF);
      end if;

      if Of_Shard.Count > 1 then
         Unbounded.Append
           (Transcript,
            "SHARD" & Positive'Image (Of_Shard.Index) & " of"
            & Positive'Image (Of_Shard.Count) & LF & LF);
      end if;

      for Item of Ordered loop
         if Item.Divided then
            Owned := True;
         else
            Owned := Owns (Of_Shard, Ordinal);
            Ordinal := Ordinal + 1;
         end if;

         if Owned and then Matches (Item) then
            if Item.Suite /= Heading then
               Suite_Ended;
               Heading := Item.Suite;
               Unbounded.Append
                 (Transcript, Unbounded.To_String (Heading) & LF);
            end if;

            declare
               State : Context;
               Label : constant String := Unbounded.To_String (Item.Name);
               Began : constant Ada.Calendar.Time := Ada.Calendar.Clock;
               --  A harness case runs a nested Run; it gets its own shard
               --  back when that one ends.
               Outer : constant Shard := Current;
            begin
               Current := (if Item.Divided then Of_Shard else Whole);

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

               Current := Outer;

               if Record_Timings then
                  Recorded.Append
                    (Timing'(Suite   => Item.Suite,
                             Name    => Item.Name,
                             Seconds => Ada.Calendar."-"
                                          (Ada.Calendar.Clock, Began)));
               end if;

               Result.Cases  := Result.Cases + 1;
               Suite_Cases   := Suite_Cases + 1;
               Result.Checks := Result.Checks + Checks (State);

               if Failures (State) = 0 then
                  Result.Passed := Result.Passed + 1;
                  Unbounded.Append (Transcript, "  pass  " & Label & LF);
               else
                  Result.Failed := Result.Failed + 1;
                  Suite_Failed  := Suite_Failed + 1;
                  Unbounded.Append (Transcript, "  FAIL  " & Label & LF);
                  Unbounded.Append (Transcript, Failure_Text (State));
               end if;
            end;
         end if;
      end loop;
      Suite_Ended;

      Unbounded.Append
        (Transcript,
         LF & "cases" & Natural'Image (Result.Cases)
         & ", passed" & Natural'Image (Result.Passed)
         & ", failed" & Natural'Image (Result.Failed)
         & ", checks" & Natural'Image (Result.Checks) & LF);
   end Run_Selected;

end Landin.Testing;
