with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;
with Landin.Backend;
with Landin.Backend.Dispatch;
with Landin.Backend.Entry_Point;
with Landin.Json;
with Landin.Memory;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Source.Names;
with Landin.Targets.Levels;

package body Landin.Build_Reports.Stacks is
   package US renames Ada.Strings.Unbounded;
   package IR renames Landin.IR;
   use type IR.Item_Id;
   use type IR.Item_Kind;
   use type IR.Opcode;
   use type IR.Declaration_Id;
   use type Landin.Memory.Operation;
   use type Landin.Source.Source_Id;
   use type Landin.Targets.Byte_Count;

   LF : constant Character := Character'Val (10);

   subtype Bytes is Landin.Targets.Byte_Count;

   --  Where a graph is opened (D468).  A recursion is the call that
   --  closes a cycle; the others are where the call or the text is.
   type Opening_Kind is
     (Function_Value, Any_Call, Evidence_Call, Foreign_Call, Recursion,
      Helper, Assembly);

   function Spelling (Kind : Opening_Kind) return String is
     (case Kind is
         when Function_Value => "function value",
         when Any_Call => "any",
         when Evidence_Call => "evidence",
         when Foreign_Call => "foreign",
         when Recursion => "recursion",
         when Helper => "helper",
         when Assembly => "assembly");

   type Opening is record
      Kind   : Opening_Kind;
      Within : IR.Item_Id;
      Site   : Landin.Provenance.Origin;
      --  The routine called, when the call names one: the external item
      --  of a foreign call, the routine a recursive call re-enters.
      Callee : IR.Item_Id := IR.No_Item;
   end record;

   type Edge is record
      From, To : IR.Item_Id;
      Site     : Landin.Provenance.Origin;
      --  The recursion opening this edge is, or zero.
      Opened   : Natural := 0;
   end record;

   package Opening_Vectors is new Ada.Containers.Vectors (Positive, Opening);
   package Edge_Vectors is new Ada.Containers.Vectors (Positive, Edge);
   package Index_Vectors is new Ada.Containers.Vectors (Positive, Positive);
   package Definitions is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => IR.Item_Id,
      Hash => Ada.Strings.Hash, Equivalent_Keys => "=", "=" => IR."=");

   function Trimmed (Text : String) return String
     is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Image (Value : Bytes) return String
     is (Trimmed (Bytes'Image (Value)));

   function Image (Value : Natural) return String
     is (Trimmed (Natural'Image (Value)));

   function Boolean_Image (Value : Boolean) return String
     is (if Value then "true" else "false");

   --  Whether a [1630] block's text may move the stack pointer or call
   --  something no IR call names: a push or a pop, x86's enter and leave,
   --  a call or branch-and-link, or any spelling of a stack pointer.  The
   --  checker already refuses most of these by target (D468); the rest a
   --  backend emits as written and does not track.
   function Moves_Stack (Text : String) return Boolean;

   function Moves_Stack (Text : String) return Boolean is
      Lowered : constant String := Ada.Characters.Handling.To_Lower (Text);
      First : Natural := 0;

      function Is_Word_Character (C : Character) return Boolean
        is (C in 'a' .. 'z' | '0' .. '9' | '_' | '.');

      function Risky (Word : String) return Boolean
        is ((Word'Length >= 4
             and then Word (Word'First .. Word'First + 3) = "push")
            or else (Word'Length >= 3
                     and then Word (Word'First .. Word'First + 2) = "pop")
            or else (Word'Length >= 4
                     and then Word (Word'First .. Word'First + 3) = "call")
            or else Word in "enter" | "leave" | "bl" | "blx" | "blr"
              | "jal" | "jalr" | "tail" | "sp" | "rsp" | "esp" | "wsp"
              | "msp" | "psp" | "r13" | "x2");
   begin
      for Index in Lowered'Range loop
         if Is_Word_Character (Lowered (Index)) then
            if First = 0 then
               First := Index;
            end if;
            if Index = Lowered'Last
              and then Risky (Lowered (First .. Index))
            then
               return True;
            end if;
         elsif First /= 0 then
            if Risky (Lowered (First .. Index - 1)) then
               return True;
            end if;
            First := 0;
         end if;
      end loop;
      return False;
   end Moves_Stack;

   function JSON
     (Of_Report    : Report;
      Context      : in out Landin.Stages.Compilation;
      Options      : Landin.Optimization.Options;
      Panic        : Landin.Panics.Plan;
      Hosted_Entry : Landin.IR.Item_Id) return String
   is
      Unit : IR.Unit renames Landin.Stages.Code (Context).all;
      Meanings : Landin.Resolution.Table renames
        Landin.Stages.Meanings (Context).all;
      Names : Landin.Source.Names.Table renames
        Landin.Stages.Identities (Context).all;
      Facts : constant Landin.Targets.Target_Facts :=
        Landin.Stages.Target (Context);
      Machine : constant Landin.Backend.Dispatch.Stack_Facts :=
        Landin.Backend.Dispatch.Stack_Facts_Of (Facts);
      Count : constant Natural := IR.Item_Count (Unit);
      Handler : constant IR.Item_Id := Landin.Panics.Handler (Panic);
      Initializer : constant IR.Item_Id :=
        Landin.Backend.Entry_Point.Argument_Initializer (Unit, Names);

      type Byte_Array is array (1 .. Count) of Bytes;
      type Flag_Array is array (1 .. Count) of Boolean;
      type Count_Array is array (1 .. Count) of Natural;
      type Item_Array is array (1 .. Count) of IR.Item_Id;

      --  Zero for a routine the backend emitted no body for.
      Statistic : Count_Array := [others => 0];
      Frame : Byte_Array := [others => 0];
      Traps, Switches, Taken : Flag_Array := [others => False];
      First_Edge, Last_Edge : Count_Array := [others => 0];
      First_Own, Last_Own : Count_Array := [others => 0];

      Edges : Edge_Vectors.Vector;
      Openings : Opening_Vectors.Vector;

      --  Tarjan's components, numbered in the order they complete, which
      --  is callees before callers.
      Component : Count_Array := [others => 0];
      Order : Index_Vectors.Vector;

      Depth : Byte_Array := [others => 0];
      --  The callee the deepest path goes on to; No_Item when it ends
      --  here, at a switch or at a trap, which Ends_At says.
      Next : Item_Array := [others => IR.No_Item];
      type Ending is (Here, At_Switch, At_Trap);
      Ends_At : array (1 .. Count) of Ending := [others => Here];

      Trap_Bytes : Bytes := 0;

      Result : US.Unbounded_String;

      --  Each link name a routine the backend emitted defines, so a call
      --  to an external declaration of it is a call to that routine, as
      --  the linker makes it: platform/linux's `program_main` is `main`.
      Defined : Definitions.Map;

      function Emitted (Id : IR.Item_Id) return Boolean
        is (Id /= IR.No_Item and then Statistic (Positive (Id)) /= 0);

      --  An item's name as its symbol spells it (D421), as the build
      --  report names it; "" for one that has none.
      function Name_Of (Id : IR.Item_Id) return String;

      function Name_Of (Id : IR.Item_Id) return String is
         Declared : constant IR.Declaration_Id :=
           Landin.Backend.Symbol_Declaration (Unit, Id);
      begin
         if Declared = IR.No_Declaration then
            return "";
         end if;
         return Landin.Backend.Qualified_Symbol
           (Meanings, Declared,
            Landin.Source.Names.Spelling
              (Names, Landin.Resolution.Name_Of (Meanings, Declared)));
      end Name_Of;

      function Where (Site : Landin.Provenance.Origin) return String;

      function Where (Site : Landin.Provenance.Origin) return String is
         Position : Landin.Source.Position;
      begin
         if Site.Source = Landin.Source.No_Source then
            return "";
         end if;
         Position := Landin.Source.Position_Of
           (Landin.Stages.Source (Context, Site.Source), Site.Where.First);
         return ",""file"":" & Landin.Json.Quoted
             (Landin.Panics.Displayed_Name (Context, Site.Source))
           & ",""line"":"
           & Trimmed (Landin.Source.Line_Number'Image (Position.Line))
           & ",""column"":"
           & Trimmed (Landin.Source.Column_Number'Image (Position.Column));
      end Where;

      --  The name the linker sees, before any platform prefix, as
      --  Landin.Backend.Entry_Point reads it.
      function Link_Name (Id : IR.Item_Id) return String;

      function Link_Name (Id : IR.Item_Id) return String is
         use type Landin.Source.Names.Name_Id;
         Link : constant Landin.Source.Names.Name_Id :=
           IR.Link_Symbol (Unit, Id);
         Declared : constant IR.Declaration_Id := IR.Declares (Unit, Id);
      begin
         if Link /= Landin.Source.Names.No_Name then
            return Landin.Source.Names.Spelling (Names, Link);
         elsif Declared = IR.No_Declaration then
            return "";
         end if;
         return Landin.Source.Names.Spelling
           (Names, Landin.Resolution.Name_Of (Meanings, Declared));
      end Link_Name;

      procedure Open
        (Kind : Opening_Kind; Within : IR.Item_Id;
         Site : Landin.Provenance.Origin;
         Callee : IR.Item_Id := IR.No_Item);

      procedure Open
        (Kind : Opening_Kind; Within : IR.Item_Id;
         Site : Landin.Provenance.Origin;
         Callee : IR.Item_Id := IR.No_Item) is
      begin
         Openings.Append (Opening'(Kind, Within, Site, Callee));
      end Open;

      procedure Call
        (From, To : IR.Item_Id; Site : Landin.Provenance.Origin);

      procedure Call
        (From, To : IR.Item_Id; Site : Landin.Provenance.Origin) is
      begin
         if IR.Is_External (Unit, To)
           and then Defined.Contains (Link_Name (To))
         then
            Edges.Append (Edge'(From, Defined (Link_Name (To)), Site, 0));
         elsif IR.Is_External (Unit, To) or else not Emitted (To) then
            Open (Foreign_Call, From, Site, To);
         else
            Edges.Append (Edge'(From, To, Site, 0));
         end if;
      end Call;

      --  The routine an indirect call's function operand is, when it is
      --  computed in the same routine from a routine's address or from a
      --  constant table; otherwise the opening it is.
      procedure Indirect
        (Within : IR.Item_Id; Value : IR.Value_Id);

      --  What a function operand was computed from, through as many
      --  loads of a slot written once in the routine as lowering put
      --  between them.  It names the kind of an opening only: a slot
      --  may also be written through its address, so a call it reaches
      --  is never closed by it.
      function Traced
        (Within : IR.Item_Id; Value : IR.Value_Id) return IR.Value_Id;

      function Traced
        (Within : IR.Item_Id; Value : IR.Value_Id) return IR.Value_Id
      is
         use type IR.Slot_Id;
         Current : IR.Value_Id := Value;
      begin
         for Hop in 1 .. 8 loop
            exit when IR.Op_Of (Unit, Within, Current) /= IR.Load;
            declare
               Slot : constant IR.Slot_Id :=
                 IR.Slot_Of (Unit, Within, Current);
               Stores : Natural := 0;
               Stored : IR.Value_Id := IR.No_Value;
            begin
               for Block in 1 .. IR.Block_Count (Unit, Within) loop
                  for Position in 1 .. IR.Length
                    (Unit, Within, IR.Block_Id (Block))
                  loop
                     declare
                        Other : constant IR.Value_Id := IR.Nth_Value
                          (Unit, Within, IR.Block_Id (Block), Position);
                     begin
                        if IR.Op_Of (Unit, Within, Other) = IR.Store
                          and then IR.Slot_Of (Unit, Within, Other) = Slot
                        then
                           Stores := Stores + 1;
                           Stored := IR.Nth_Operand (Unit, Within, Other, 1);
                        end if;
                     end;
                  end loop;
               end loop;
               exit when Stores /= 1;
               Current := Stored;
            end;
         end loop;
         return Current;
      end Traced;

      procedure Indirect
        (Within : IR.Item_Id; Value : IR.Value_Id)
      is
         Site : constant Landin.Provenance.Origin :=
           IR.Origin_Of (Unit, Within, Value);
         Callee : constant IR.Value_Id :=
           IR.Nth_Operand (Unit, Within, Value, 1);
         Op : constant IR.Opcode := IR.Op_Of (Unit, Within, Callee);
         Source : constant IR.Value_Id := Traced (Within, Callee);
         Kind : constant IR.Opcode := IR.Op_Of (Unit, Within, Source);
      begin
         if Op = IR.Function_Address then
            Call (Within, IR.Callee_Of (Unit, Within, Callee), Site);
         elsif Op = IR.Evidence_Function
           and then not IR.Evidence_Is_Erased
             (Unit, IR.Evidence_Of (Unit, Within, Callee))
           and then IR.Op_Of
             (Unit, Within, IR.Nth_Operand (Unit, Within, Callee, 1))
             = IR.Evidence_Address
         then
            --  A constant table: the entry is the routine called.
            Call (Within,
                  IR.Evidence_Entry_Target
                    (Unit,
                     IR.Evidence_Of
                       (Unit, Within,
                        IR.Nth_Operand (Unit, Within, Callee, 1)),
                     IR.Evidence_Entry_Of (Unit, Within, Callee)),
                  Site);
         elsif Kind = IR.Evidence_Function then
            Open ((if IR.Evidence_Is_Erased
                     (Unit, IR.Evidence_Of (Unit, Within, Source))
                   then Any_Call else Evidence_Call),
                  Within, Site);
         elsif Kind = IR.Code_Address then
            Open (Foreign_Call, Within, Site);
         else
            Open (Function_Value, Within, Site);
         end if;
      end Indirect;

      procedure Read_Routine (Id : IR.Item_Id);

      procedure Read_Routine (Id : IR.Item_Id) is
         Facts_Of : constant Routine_Statistics :=
           Nth_Routine (Of_Report, Statistic (Positive (Id)));
         Body_Of : constant Routine_Statistics :=
           (if Facts_Of.Shared_With = IR.No_Item then Facts_Of
            else Nth_Routine
              (Of_Report, Statistic (Positive (Facts_Of.Shared_With))));
      begin
         Frame (Positive (Id)) := Body_Of.Stack_Bytes;
         Traps (Positive (Id)) := Body_Of.Calls_Panic;
         First_Edge (Positive (Id)) := Natural (Edges.Length) + 1;
         First_Own (Positive (Id)) := Natural (Openings.Length) + 1;
         if Body_Of.Naked then
            Open (Assembly, Id, IR.Origin_Of (Unit, Id));
         else
            for Block in 1 .. IR.Block_Count (Unit, Id) loop
               for Position in 1 .. IR.Length
                 (Unit, Id, IR.Block_Id (Block))
               loop
                  declare
                     Value : constant IR.Value_Id := IR.Nth_Value
                       (Unit, Id, IR.Block_Id (Block), Position);
                  begin
                     case IR.Op_Of (Unit, Id, Value) is
                        when IR.Call =>
                           Call (Id, IR.Callee_Of (Unit, Id, Value),
                                 IR.Origin_Of (Unit, Id, Value));
                        when IR.Indirect_Call =>
                           Indirect (Id, Value);
                        when IR.Memory_Access =>
                           if IR.Memory_Operation (Unit, Id, Value)
                             = Landin.Memory.Stack_Switch
                           then
                              Switches (Positive (Id)) := True;
                           end if;
                        when IR.Assembly =>
                           if Moves_Stack
                             (Landin.Backend.Assembly_Text
                                (Unit, Id, Value, Names, Facts))
                           then
                              Open (Assembly, Id,
                                    IR.Origin_Of (Unit, Id, Value));
                           end if;
                        when others =>
                           null;
                     end case;
                  end;
               end loop;
            end loop;
         end if;
         if Body_Of.Helper_Calls > 0 then
            Open (Helper, Id, IR.Origin_Of (Unit, Id));
         end if;
         --  The hosted entry calls the argument initializer before its
         --  own frame is reserved, which counting it as a call from the
         --  whole frame bounds.
         if Id = Hosted_Entry and then Initializer /= IR.No_Item then
            Call (Id, Initializer, IR.Origin_Of (Unit, Id));
         end if;
         Last_Edge (Positive (Id)) := Natural (Edges.Length);
         Last_Own (Positive (Id)) := Natural (Openings.Length);
      end Read_Routine;

      --  Tarjan's strongly connected components.
      Visit_Index, Low : Count_Array := [others => 0];
      On_Stack : Flag_Array := [others => False];
      Stack : Index_Vectors.Vector;
      Visited, Components : Natural := 0;

      procedure Connect (Id : Positive);

      procedure Connect (Id : Positive) is
      begin
         Visited := Visited + 1;
         Visit_Index (Id) := Visited;
         Low (Id) := Visited;
         Stack.Append (Id);
         On_Stack (Id) := True;
         for E in First_Edge (Id) .. Last_Edge (Id) loop
            declare
               To : constant Positive := Positive (Edges (E).To);
            begin
               if Visit_Index (To) = 0 then
                  Connect (To);
                  Low (Id) := Natural'Min (Low (Id), Low (To));
               elsif On_Stack (To) then
                  Low (Id) := Natural'Min (Low (Id), Visit_Index (To));
               end if;
            end;
         end loop;
         if Low (Id) = Visit_Index (Id) then
            Components := Components + 1;
            loop
               declare
                  Top : constant Positive := Stack.Last_Element;
               begin
                  Stack.Delete_Last;
                  On_Stack (Top) := False;
                  Component (Top) := Components;
                  Order.Append (Top);
                  exit when Top = Id;
               end;
            end loop;
         end if;
      end Connect;

      --  Each routine's depth, callees first.  Calls inside one component
      --  are recursion and are not followed: the depth is what the rest
      --  of the graph closes.
      procedure Measure;

      procedure Measure is
      begin
         for Id of Order loop
            declare
               Best : Bytes := 0;
               Ends : Ending := Here;
               Callee : IR.Item_Id := IR.No_Item;
            begin
               for E in First_Edge (Id) .. Last_Edge (Id) loop
                  declare
                     To : constant Positive := Positive (Edges (E).To);
                  begin
                     if Component (To) /= Component (Id)
                       and then Depth (To) > Best
                     then
                        Best := Depth (To);
                        Ends := Here;
                        Callee := IR.Item_Id (To);
                     end if;
                  end;
               end loop;
               if Switches (Id) and then Machine.Switch_Bytes > Best then
                  Best := Machine.Switch_Bytes;
                  Ends := At_Switch;
                  Callee := IR.No_Item;
               end if;
               if Traps (Id) and then Trap_Bytes > Best then
                  Best := Trap_Bytes;
                  Ends := At_Trap;
                  Callee := IR.No_Item;
               end if;
               Depth (Id) := Frame (Id) + Best;
               Next (Id) := Callee;
               Ends_At (Id) := Ends;
            end;
         end loop;
      end Measure;

      --  The openings reachable from Root, in their order.
      Reached_Stamp : Count_Array := [others => 0];
      Stamp : Natural := 0;

      function Reached (Root : Positive) return Index_Vectors.Vector;

      function Reached (Root : Positive) return Index_Vectors.Vector is
         Pending : Index_Vectors.Vector;
         Found : Index_Vectors.Vector;
         Marks : array (1 .. Natural (Openings.Length)) of Boolean :=
           [others => False];
      begin
         Stamp := Stamp + 1;
         Pending.Append (Root);
         Reached_Stamp (Root) := Stamp;
         while not Pending.Is_Empty loop
            declare
               Id : constant Positive := Pending.Last_Element;
            begin
               Pending.Delete_Last;
               for Own in First_Own (Id) .. Last_Own (Id) loop
                  Marks (Own) := True;
               end loop;
               for E in First_Edge (Id) .. Last_Edge (Id) loop
                  if Edges (E).Opened /= 0 then
                     Marks (Edges (E).Opened) := True;
                  end if;
                  declare
                     To : constant Positive := Positive (Edges (E).To);
                  begin
                     if Reached_Stamp (To) /= Stamp then
                        Reached_Stamp (To) := Stamp;
                        Pending.Append (To);
                     end if;
                  end;
               end loop;
            end;
         end loop;
         for Index in Marks'Range loop
            if Marks (Index) then
               Found.Append (Index);
            end if;
         end loop;
         return Found;
      end Reached;

      procedure Put (Text : String);

      procedure Put (Text : String) is
      begin
         US.Append (Result, Text);
      end Put;

      procedure Put_List (List : Index_Vectors.Vector);

      procedure Put_List (List : Index_Vectors.Vector) is
         First : Boolean := True;
      begin
         Put ("[");
         for Index of List loop
            Put ((if First then "" else ",") & Image (Index));
            First := False;
         end loop;
         Put ("]");
      end Put_List;

      Trap_Openings : Index_Vectors.Vector;
      Trap_Calls : constant String :=
        (if Handler /= IR.No_Item then "handler"
         elsif Landin.Panics.Reports_Default (Panic) then "report"
         else "none");
   begin
      for Index in 1 .. Routine_Count (Of_Report) loop
         declare
            Id : constant IR.Item_Id := Nth_Routine (Of_Report, Index).Item;
         begin
            Statistic (Positive (Id)) := Index;
         end;
      end loop;
      for Index in 1 .. Count loop
         declare
            Id : constant IR.Item_Id := IR.Item_Id (Index);
         begin
            if IR.Kind_Of (Unit, Id) = IR.Routine and then Emitted (Id)
              and then not IR.Is_External (Unit, Id)
              and then Landin.Backend.Is_Exported
                (Unit, Meanings, Id, Hosted_Entry)
              and then Link_Name (Id) /= ""
              and then not Defined.Contains (Link_Name (Id))
            then
               Defined.Insert (Link_Name (Id), Id);
            end if;
         end;
      end loop;
      for Index in 1 .. Count loop
         declare
            Id : constant IR.Item_Id := IR.Item_Id (Index);
         begin
            if IR.Kind_Of (Unit, Id) = IR.Routine and then Emitted (Id) then
               Read_Routine (Id);
               for Block in 1 .. IR.Block_Count (Unit, Id) loop
                  for Position in 1 .. IR.Length
                    (Unit, Id, IR.Block_Id (Block))
                  loop
                     declare
                        Value : constant IR.Value_Id := IR.Nth_Value
                          (Unit, Id, IR.Block_Id (Block), Position);
                     begin
                        if IR.Op_Of (Unit, Id, Value) = IR.Function_Address
                        then
                           declare
                              Callee : constant IR.Item_Id :=
                                IR.Callee_Of (Unit, Id, Value);
                           begin
                              Taken (Positive (Callee)) := True;
                           end;
                        end if;
                     end;
                  end loop;
               end loop;
            end if;
         end;
      end loop;
      for Table in 1 .. IR.Evidence_Count (Unit) loop
         for Which in 1 .. IR.Evidence_Entry_Count
           (Unit, IR.Evidence_Id (Table))
         loop
            declare
               Target : constant IR.Item_Id := IR.Evidence_Entry_Target
                 (Unit, IR.Evidence_Id (Table), Which);
            begin
               if Target /= IR.No_Item then
                  Taken (Positive (Target)) := True;
               end if;
            end;
         end loop;
      end loop;

      for Index in 1 .. Count loop
         if Emitted (IR.Item_Id (Index)) and then Visit_Index (Index) = 0
           and then IR.Kind_Of (Unit, IR.Item_Id (Index)) = IR.Routine
         then
            Connect (Index);
         end if;
      end loop;
      for E in 1 .. Natural (Edges.Length) loop
         declare
            Call_Edge : Edge := Edges (E);
         begin
            if Component (Positive (Call_Edge.From))
              = Component (Positive (Call_Edge.To))
            then
               Open (Recursion, Call_Edge.From, Call_Edge.Site,
                     Call_Edge.To);
               Call_Edge.Opened := Natural (Openings.Length);
               Edges.Replace_Element (E, Call_Edge);
            end if;
         end;
      end loop;

      --  A failed check calls the handler on the stack it failed on, and
      --  a check failing inside the handler's own calls enters it once
      --  more, as far as its reserved frame, before it traps: so the
      --  handler is measured with its own frame as the trap's cost, and
      --  every routine with what that measured.
      if Handler /= IR.No_Item and then Emitted (Handler) then
         Trap_Bytes := Frame (Positive (Handler));
         Measure;
         Trap_Bytes := Depth (Positive (Handler));
         Trap_Openings := Reached (Positive (Handler));
      elsif Landin.Panics.Reports_Default (Panic) then
         Trap_Bytes := Machine.Report_Bytes;
      end if;
      Measure;

      Put ("{""format"":""landin-stack-report-1"",""target"":"
           & Landin.Json.Quoted (Landin.Targets.Name (Facts))
           & ",""level"":" & Landin.Json.Quoted
             (Landin.Targets.Levels.Name (Landin.Stages.Level (Context)))
           & ",""optimize"":" & Landin.Json.Quoted
             (Landin.Optimization.Spelling (Options.Optimize))
           & ",""specialize"":" & Landin.Json.Quoted
             (Landin.Optimization.Spelling (Options.Specialize))
           & ",""switch_bytes"":" & Image (Machine.Switch_Bytes)
           & ",""prepared_bytes"":" & Image (Machine.Prepared_Bytes)
           & ",""entry_bytes"":" & Image (Machine.Entry_Bytes)
           & "," & LF & """trap"":{""calls"":""" & Trap_Calls & """");
      if Handler /= IR.No_Item then
         Put (",""routine"":" & Landin.Json.Quoted (Name_Of (Handler)));
      end if;
      Put (",""depth_bytes"":" & Image (Trap_Bytes)
           & ",""closed"":" & Boolean_Image
             (Trap_Openings.Is_Empty
              and then not (Trap_Calls = "report"
                            and then Machine.Report_Foreign))
           & ",""foreign_write"":" & Boolean_Image
             (Trap_Calls = "report" and then Machine.Report_Foreign)
           & ",""openings"":");
      Put_List (Trap_Openings);
      Put ("}," & LF & """openings"":[");
      for Index in 1 .. Natural (Openings.Length) loop
         declare
            Found : constant Opening := Openings (Index);
         begin
            Put ((if Index > 1 then "," else "") & LF
                 & "{""opening"":" & Image (Index)
                 & ",""kind"":" & Landin.Json.Quoted (Spelling (Found.Kind))
                 & ",""routine"":" & Landin.Json.Quoted
                   (Name_Of (Found.Within))
                 & Where (Found.Site));
            if Found.Callee /= IR.No_Item then
               Put (",""callee"":" & Landin.Json.Quoted
                      (Name_Of (Found.Callee)));
            end if;
            Put ("}");
         end;
      end loop;
      Put ("]," & LF & """routines"":[");
      declare
         First : Boolean := True;
      begin
         for Index in 1 .. Count loop
            if Emitted (IR.Item_Id (Index))
              and then IR.Kind_Of (Unit, IR.Item_Id (Index)) = IR.Routine
            then
               declare
                  Id : constant IR.Item_Id := IR.Item_Id (Index);
                  Opened : constant Index_Vectors.Vector := Reached (Index);
                  Closed : constant Boolean := Opened.Is_Empty
                    and then not (Traps (Index)
                      and then (not Trap_Openings.Is_Empty
                                or else (Trap_Calls = "report"
                                         and then Machine.Report_Foreign)));
                  Step : Positive := Index;
               begin
                  Put ((if First then "" else ",") & LF
                       & "{""item"":" & Image (Index)
                       & ",""name"":" & Landin.Json.Quoted (Name_Of (Id))
                       & Where (IR.Origin_Of (Unit, Id))
                       & ",""frame_bytes"":" & Image (Frame (Index))
                       & ",""depth_bytes"":" & Image (Depth (Index))
                       & ",""closed"":" & Boolean_Image (Closed)
                       & ",""address_taken"":" & Boolean_Image (Taken (Index))
                       & ",""switches"":" & Boolean_Image (Switches (Index))
                       & ",""traps"":" & Boolean_Image (Traps (Index))
                       & ",""path"":[" & Landin.Json.Quoted (Name_Of (Id)));
                  First := False;
                  loop
                     if Next (Step) /= IR.No_Item then
                        Step := Positive (Next (Step));
                        Put ("," & Landin.Json.Quoted
                               (Name_Of (IR.Item_Id (Step))));
                     else
                        case Ends_At (Step) is
                           when At_Switch =>
                              Put (",""(switch)""");
                           when At_Trap =>
                              Put (",""(trap)""");
                           when Here =>
                              null;
                        end case;
                        exit;
                     end if;
                  end loop;
                  Put ("],""openings"":");
                  Put_List (Opened);
                  Put ("}");
               end;
            end if;
         end loop;
      end;
      Put ("]}" & LF);
      return US.To_String (Result);
   end JSON;

end Landin.Build_Reports.Stacks;
