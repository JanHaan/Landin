with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Backend.Debug_Locations;
with Landin.Backend.X86_64.Allocation;
with Landin.Backend.X86_64.Dwarf;
with Landin.Debugging;
with Landin.Driver;
with Landin.IR;
with Landin.Optimization;
with Landin.Platform;
with Landin.Resolution;
with Landin.Source;
with Landin.Source.Names;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Testing.Fakes;

package body Landin.Tests.Debugging_Suite is

   package US renames Ada.Strings.Unbounded;
   package IR renames Landin.IR;
   use type IR.Declaration_Id;
   use type IR.Item_Kind;
   use type IR.Opcode;
   use type IR.Item_Id;
   use type IR.Slot_Id;
   use type Landin.Source.Source_Id;
   use type Landin.Source.Byte_Offset;
   LF : constant Character := Character'Val (10);
   Simple : constant String :=
     "public main: () -> (code: i32) = code = 0 end main";
   Frontend : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver : aliased Landin.Stages.Resolution.Instance;
   Checker : aliased Landin.Stages.Checking.Instance;
   Lowerer : aliased Landin.Stages.Lowering.Instance;

   function Contains (Text, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   function Request return Landin.Platform.Path_List;
   function Request return Landin.Platform.Path_List is
      Args : Landin.Platform.Path_List;
   begin
      Args.Append ("main.ldn");
      Args.Append ("--emit=asm");
      Args.Append ("-o");
      Args.Append ("out.s");
      return Args;
   end Request;

   procedure Invalid_Requests (Item : in out Landin.Testing.Context);
   procedure Defaults (Item : in out Landin.Testing.Context);
   procedure Source_Maps (Item : in out Landin.Testing.Context);
   procedure Path_Bytes (Item : in out Landin.Testing.Context);
   procedure Fieldwise (Item : in out Landin.Testing.Context);
   procedure Stored_Returns (Item : in out Landin.Testing.Context);
   procedure Scopes (Item : in out Landin.Testing.Context);
   procedure Loops (Item : in out Landin.Testing.Context);
   procedure Arrays (Item : in out Landin.Testing.Context);
   procedure Failing_Returns (Item : in out Landin.Testing.Context);
   procedure Aliases (Item : in out Landin.Testing.Context);

   procedure Invalid_Requests (Item : in out Landin.Testing.Context) is
      procedure Refuses (First : String; Second : String := "");
      procedure Refuses (First : String; Second : String := "") is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List := Request;
         Result : Landin.Driver.Outcome;
      begin
         Host.Add_File ("main.ldn", Simple);
         Args.Append (First);
         if Second /= "" then
            Args.Append (Second);
         end if;
         Result := Landin.Driver.Execute (Args, Host, Tools);
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Misuse,
            First & " " & Second & " is request misuse");
         Landin.Testing.Check
           (Item, Host.Written ("out.s") = "" and then Tools.Run_Count = 0,
            "invalid debug requests have no output effects");
      end Refuses;
   begin
      Refuses ("--debug=");
      Refuses ("--debug=FULL");
      Refuses ("--debug=line");
      Refuses ("--debug=none", "--debug=none");
      Refuses ("--debug=full", "--debug=none");
      Refuses ("--debug=full", "--help");
      Refuses ("--debug=none", "--identify");
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : constant Landin.Driver.Outcome := Landin.Driver.Execute
           (Landin.Platform.Arguments ("--help"), Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, 0, "standalone help succeeds");
         Landin.Testing.Check
           (Item, Contains (US.To_String (Result.Output), "--debug=NAME")
            and then Contains (US.To_String (Result.Output),
              "none (default) or full source debugging"),
            "help documents debug choices and the default");
      end;
   end Invalid_Requests;

   procedure Defaults (Item : in out Landin.Testing.Context) is
   begin
      for Mode in 1 .. 2 loop
         for Optimize in 1 .. 3 loop
            declare
               Host, None_Host, Full_Host :
                 Landin.Testing.Fakes.Fake_Filesystem;
               Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
               Args : Landin.Platform.Path_List := Request;
               Result : Landin.Driver.Outcome;
               Assembly : US.Unbounded_String;
            begin
               Host.Add_File ("main.ldn", Simple);
               Args.Append ("--build-mode=" &
                 (if Mode = 1 then "debug" else "release"));
               Args.Append ("--optimize=" &
                 (case Optimize is when 1 => "none", when 2 => "size",
                    when others => "speed"));
               Result := Landin.Driver.Execute (Args, Host, Tools);
               Landin.Testing.Check_Equal
                 (Item, Result.Status, 0, "default debug emission succeeds");
               Assembly := US.To_Unbounded_String (Host.Written ("out.s"));
               None_Host.Add_File ("main.ldn", Simple);
               Args.Append ("--debug=none");
               Result := Landin.Driver.Execute (Args, None_Host, Tools);
               Landin.Testing.Check_Equal
                 (Item, Result.Status, 0, "explicit none succeeds");
               Landin.Testing.Check_Equal
                 (Item, None_Host.Written ("out.s"), US.To_String (Assembly),
                  "none is byte-identical to default in every mode");
               Landin.Testing.Check
                 (Item, not Contains (Host.Written ("out.s"), ".debug_")
                  and then not Contains (Host.Written ("out.s"), "main.ldn")
                  and then Host.Written
                    (Landin.Driver.Source_Map_Beside ("out.s")) = "",
                  "none without caller sites deploys no source names");
               Args.Delete_Last;
               Full_Host.Add_File ("main.ldn", Simple);
               Args.Append ("--debug=full");
               Result := Landin.Driver.Execute (Args, Full_Host, Tools);
               Landin.Testing.Check_Equal
                 (Item, Result.Status, 0, "full is independent of modes");
               Landin.Testing.Check
                 (Item, Contains (Full_Host.Written ("out.s"), ".debug_info")
                  and then Contains
                    (Full_Host.Written ("out.s"), ".cfi_startproc")
                  and then Contains (Full_Host.Written ("out.s"),
                    ".file 1 ""main.ldn"""),
                  "full keeps source identity and frame information");
            end;
         end loop;
      end loop;
   end Defaults;

   procedure Source_Maps (Item : in out Landin.Testing.Context) is
      Host, Full_Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List := Request;
      Result : Landin.Driver.Outcome;
      Caller : constant String :=
        "site: type = struct file_id: u32 line: u32 column: u32 end site"
        & LF & "capture: (caller where: site) -> (value: u32) ="
        & " value = where.line end capture" & LF
        & "public main: () -> (code: i32) = code = i32(capture()) end main";
   begin
      Host.Add_File ("main.ldn", Caller);
      Host.Add_File ("other.ldn", "other: () -> none = end other");
      Args.Append ("other.ldn");
      Result := Landin.Driver.Execute (Args, Host, Tools);
      Landin.Testing.Check_Equal
        (Item, Result.Status, 0, "caller-only map compiles");
      Landin.Testing.Check
        (Item, Contains (Host.Written
           (Landin.Driver.Source_Map_Beside ("out.s")), "6d61696e2e6c646e")
         and then not Contains (Host.Written
           (Landin.Driver.Source_Map_Beside ("out.s")), "6f746865722e6c646e")
         and then not Contains (Host.Written ("out.s"), "main.ldn"),
         "none maps only caller snapshots and keeps assembly nameless");
      Full_Host.Add_File ("main.ldn", Caller);
      Full_Host.Add_File ("other.ldn", "other: () -> none = end other");
      Args.Append ("--debug=full");
      Result := Landin.Driver.Execute (Args, Full_Host, Tools);
      Landin.Testing.Check_Equal
        (Item, Result.Status, 0, "full snapshot map compiles");
      Landin.Testing.Check
        (Item, Contains (Full_Host.Written
           (Landin.Driver.Source_Map_Beside ("out.s")), "6f746865722e6c646e")
         and then Contains
           (Full_Host.Written ("out.s"), ".file 1 ""main.ldn""")
         and then Contains
           (Full_Host.Written ("out.s"), ".file 2 ""other.ldn"""),
         "full preserves original source IDs including non-caller sources");
   end Source_Maps;

   procedure Path_Bytes (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
      Result : Landin.Driver.Outcome;
      Path : constant String := "q""\" & LF & Character'Val (255) & ".ldn";
   begin
      Host.Add_File (Path, Simple);
      Args.Append (Path);
      Args.Append ("--emit=asm");
      Args.Append ("--debug=full");
      Args.Append ("-o");
      Args.Append ("out.s");
      Result := Landin.Driver.Execute (Args, Host, Tools);
      Landin.Testing.Check_Equal
        (Item, Result.Status, 0, "arbitrary GNU path bytes compile");
      Landin.Testing.Check
        (Item, Contains (Host.Written ("out.s"),
           ".file 1 ""q\""\\\012\377.ldn"""),
         "assembler strings use escaped quotes and three-digit octal");
      Landin.Testing.Check
        (Item, Contains (Host.Written
           (Landin.Driver.Source_Map_Beside ("out.s")), "71225c0aff2e6c646e"),
         "the full source map retains every original filename byte");
   end Path_Bytes;

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String);
   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String)
   is
      Order : Landin.Stages.Pipeline;
      Source : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "debug.ldn", Text);
      Ran : Natural;
   begin
      pragma Assert (Source /= Landin.Source.No_Source);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Resolver'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "debug location program lowers through every stage");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         Landin.Stages.Rendered_Report (Work));
   end Lower;

   procedure Expect
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation;
      Text, Name, At_Text : String; Available : Boolean);
   procedure Expect
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation;
      Text, Name, At_Text : String; Available : Boolean)
   is
      Code : constant access constant IR.Unit := Landin.Stages.Code (Work);
      Meanings : constant access constant Landin.Resolution.Table :=
        Landin.Stages.Meanings (Work);
      Info : Landin.Debugging.Information (Landin.Stages.Trees (Work));
      Offset : constant Landin.Source.Byte_Offset :=
        Landin.Source.Byte_Offset
          (Ada.Strings.Fixed.Index (Text, At_Text) - 1);
      Seen : Natural := 0;
   begin
      if Landin.Stages.Failed (Work) then
         return;
      end if;
      for I in 1 .. IR.Item_Count (Code.all) loop
         if IR.Kind_Of (Code.all, IR.Item_Id (I)) = IR.Routine then
            for S in 1 .. IR.Slot_Count (Code.all, IR.Item_Id (I)) loop
               declare
                  Binding : constant IR.Declaration_Id := IR.Declares
                    (Code.all, IR.Item_Id (I), IR.Slot_Id (S));
               begin
                  if Binding /= IR.No_Declaration and then
                    Landin.Source.Names.Spelling
                      (Landin.Stages.Identities (Work).all,
                       Landin.Resolution.Name_Of
                         (Meanings.all, Binding)) = Name
                  then
                     declare
                        Flags : constant
                          Landin.Backend.Debug_Locations.Flags.Vector :=
                            Landin.Backend.Debug_Locations.Available
                              (Code.all, Meanings.all, Info,
                               IR.Item_Id (I), IR.Slot_Id (S), False);
                     begin
                        for V in 1 .. IR.Value_Count (Code.all, IR.Item_Id (I))
                        loop
                           if IR.Origin_Of
                             (Code.all, IR.Item_Id (I), IR.Value_Id (V))
                               .Where.First = Offset
                           then
                              Seen := Seen + 1;
                              Landin.Testing.Check
                                (Item, Flags (V) = Available,
                                 Name & " availability at " & At_Text);
                           end if;
                        end loop;
                     end;
                  end if;
               end;
            end loop;
            for A in 1 .. IR.Source_Alias_Count (Code.all, IR.Item_Id (I)) loop
               declare
                  Alias : constant IR.Source_Alias :=
                    IR.Nth_Source_Alias (Code.all, IR.Item_Id (I), A);
               begin
                  if Landin.Source.Names.Spelling
                    (Landin.Stages.Identities (Work).all,
                     Landin.Resolution.Name_Of
                       (Meanings.all, Alias.Binding)) = Name
                  then
                     declare
                        Flags : constant
                          Landin.Backend.Debug_Locations.Flags.Vector :=
                            Landin.Backend.Debug_Locations.Available_Alias
                              (Code.all, Meanings.all, Info,
                               IR.Item_Id (I), A);
                     begin
                        for V in 1 .. IR.Value_Count (Code.all, IR.Item_Id (I))
                        loop
                           if IR.Origin_Of
                             (Code.all, IR.Item_Id (I), IR.Value_Id (V))
                               .Where.First = Offset
                           then
                              Seen := Seen + 1;
                              Landin.Testing.Check
                                (Item, Flags (V) = Available,
                                 Name & " alias availability at " & At_Text);
                           end if;
                        end loop;
                     end;
                  end if;
               end;
            end loop;
         end if;
      end loop;
      Landin.Testing.Check
        (Item, Seen > 0, "the location assertion reaches " & At_Text);
   end Expect;

   Pair : constant String :=
     "pair: type = struct a: i32 b: i32 end pair" & LF
     & "probe: (x: i32) -> none = end probe" & LF;

   procedure Fieldwise (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Text : constant String := Pair
        & "f: (choose: bool) -> none =" & LF
        & " mut p: pair" & LF
        & " p.a = 1" & LF
        & " probe(10)" & LF
        & " if choose then p.b = 2 else p.b = 3 end if" & LF
        & " probe(20)" & LF
        & " mut partial: pair" & LF
        & " if choose then partial.a = 4 else partial.b = 5 end if" & LF
        & " probe(30)" & LF
        & "end f";
   begin
      Lower (Item, Work, Text);
      Expect (Item, Work, Text, "p", "probe(10)", False);
      Expect (Item, Work, Text, "p", "probe(20)", True);
      Expect (Item, Work, Text, "partial", "probe(30)", False);
   end Fieldwise;

   procedure Stored_Returns (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Text : constant String := Pair
        & "make: () -> (r: pair) = r = (a: 1, b: 2) end make" & LF
        & "f: () -> none =" & LF
        & " mut direct := make()" & LF
        & " probe(10)" & LF
        & " callback := make" & LF
        & " mut indirect := callback()" & LF
        & " probe(20)" & LF
        & " mut copied: pair" & LF
        & " copied = direct" & LF
        & " probe(30)" & LF
        & "end f";
   begin
      Lower (Item, Work, Text);
      Expect (Item, Work, Text, "direct", "probe(10)", True);
      Expect (Item, Work, Text, "indirect", "probe(20)", True);
      Expect (Item, Work, Text, "copied", "probe(30)", True);
   end Stored_Returns;

   procedure Scopes (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Text : constant String := Pair
        & "f: (choose: bool) -> none =" & LF
        & " mut value: i32" & LF
        & " probe(10)" & LF
        & " if choose then value = 1 else value = 2 end if" & LF
        & " probe(20)" & LF
        & " if choose then" & LF
        & "   inner: i32 = 3" & LF
        & "   probe(30)" & LF
        & " end if" & LF
        & " probe(40)" & LF
        & "end f";
   begin
      Lower (Item, Work, Text);
      Expect (Item, Work, Text, "value", "probe(10)", False);
      Expect (Item, Work, Text, "value", "probe(20)", True);
      Expect (Item, Work, Text, "inner", "probe(30)", True);
      Expect (Item, Work, Text, "inner", "probe(40)", False);
   end Scopes;

   procedure Loops (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Text : constant String := Pair
        & "f: () -> none =" & LF
        & " mut i: i32 = 0" & LF
        & " while i < 2 do" & LF
        & "   mut local: pair" & LF
        & "   probe(10)" & LF
        & "   local.a = 1" & LF
        & "   probe(20)" & LF
        & "   local.b = 2" & LF
        & "   probe(30)" & LF
        & "   inc i" & LF
        & " end while" & LF
        & " probe(40)" & LF
        & "end f";
   begin
      Lower (Item, Work, Text);
      Expect (Item, Work, Text, "local", "probe(10)", False);
      Expect (Item, Work, Text, "local", "probe(20)", False);
      Expect (Item, Work, Text, "local", "probe(30)", True);
      Expect (Item, Work, Text, "local", "probe(40)", False);
   end Loops;

   procedure Arrays (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Text : constant String := Pair
        & "holder: type = struct child: pair row: [2]i32 end holder" & LF
        & "f: () -> none =" & LF
        & " mut h: holder" & LF
        & " h.child.a = 1 h.child.b = 2" & LF
        & " probe(10)" & LF
        & " h.row[0] = 3" & LF
        & " probe(20)" & LF
        & " h.row[1] = 4" & LF
        & " probe(30)" & LF
        & " mut source: holder = zeroed" & LF
        & " mut copied: holder" & LF
        & " copied = source" & LF
        & " probe(40)" & LF
        & " mut flat: [2]i32" & LF
        & " flat[0] = 1 flat[1] = 2" & LF
        & " probe(50)" & LF
        & " mut records: [1]pair" & LF
        & " records[0].a = 1 records[0].b = 2" & LF
        & " probe(60)" & LF
        & "end f";
   begin
      Lower (Item, Work, Text);
      Expect (Item, Work, Text, "h", "probe(10)", False);
      Expect (Item, Work, Text, "h", "probe(20)", False);
      Expect (Item, Work, Text, "h", "probe(30)", True);
      Expect (Item, Work, Text, "copied", "probe(40)", True);
      Expect (Item, Work, Text, "flat", "probe(50)", True);
      Expect (Item, Work, Text, "records", "probe(60)", True);
   end Arrays;

   procedure Failing_Returns (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Text : constant String := Pair
        & "missing: atom" & LF
        & "make: (reject: bool) -> (r: pair) ! missing =" & LF
        & " fail missing when reject r = (a: 1, b: 2) end make" & LF
        & "f: (reject: bool) -> none =" & LF
        & " mut p: pair" & LF
        & " p = make(reject) else (problem)" & LF
        & "   _ = problem probe(10) pair(a: 3, b: 4)" & LF
        & " end" & LF
        & " probe(20)" & LF
        & "end f";
   begin
      Lower (Item, Work, Text);
      Expect (Item, Work, Text, "p", "probe(10)", False);
      Expect (Item, Work, Text, "p", "probe(20)", True);
   end Failing_Returns;

   procedure Aliases (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Text : constant String := Pair
        & "divide: () -> (quot: i32, rem: i32) =" & LF
        & " probe(10) quot = 3 probe(20) rem = 1 probe(30)" & LF
        & "end divide" & LF
        & "f: () -> none =" & LF
        & " (quot: quotient, rem: residue) := divide()" & LF
        & " probe(40)" & LF
        & "end f";
   begin
      Lower (Item, Work, Text);
      Expect (Item, Work, Text, "quot", "probe(10)", False);
      Expect (Item, Work, Text, "quot", "probe(20)", True);
      Expect (Item, Work, Text, "rem", "probe(20)", False);
      Expect (Item, Work, Text, "rem", "probe(30)", True);
      Expect (Item, Work, Text, "quotient", "probe(40)", True);
      Expect (Item, Work, Text, "residue", "probe(40)", True);
   end Aliases;

   procedure Register_Locations_Preserve_Indirection
     (Item : in out Landin.Testing.Context);

   procedure Register_Locations_Preserve_Indirection
     (Item : in out Landin.Testing.Context)
   is
      package Dwarf renames Landin.Backend.X86_64.Dwarf;
      package Allocation renames Landin.Backend.X86_64.Allocation;
      HT : constant Character := Character'Val (9);
   begin
      Landin.Testing.Check_Equal
        (Item, Dwarf.Register_Location (Allocation.RBX, False),
         HT & ".byte 83" & LF, "a direct RBX value uses DW_OP_reg3");
      Landin.Testing.Check_Equal
        (Item, Dwarf.Register_Location (Allocation.RBX, True),
         HT & ".byte 115" & LF & HT & ".sleb128 0" & LF,
         "an address in RBX uses DW_OP_breg3 with zero displacement");
      Landin.Testing.Check_Equal
        (Item, Dwarf.Register_Location (Allocation.R15, False),
         HT & ".byte 95" & LF, "a direct R15 value uses DW_OP_reg15");
      Landin.Testing.Check_Equal
        (Item, Dwarf.Register_Location (Allocation.R15, True),
         HT & ".byte 127" & LF & HT & ".sleb128 0" & LF,
         "an address in R15 uses DW_OP_breg15 with zero displacement");
   end Register_Locations_Preserve_Indirection;

   procedure Whole_Aliases_Require_Array_Storage
     (Item : in out Landin.Testing.Context);

   procedure Whole_Aliases_Require_Array_Storage
     (Item : in out Landin.Testing.Context)
   is
      procedure Check (From_Module, Array_Storage : Boolean);

      procedure Check (From_Module, Array_Storage : Boolean) is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Text : constant String :=
           (if Array_Storage then
              "data: [1]i32 = [1] f: () -> none = "
              & "local: [1]i32 = [2] end f"
            else "data: i32 = 1 f: () -> none = local: i32 = 2 end f");
         Expected : constant String :=
           (if From_Module then "a whole datum alias requires array storage"
            else "a whole slot alias requires array storage");
      begin
         Lower (Item, Work, Text);
         if Landin.Stages.Failed (Work) then
            return;
         end if;
         declare
            Unit : IR.Unit renames Landin.Stages.Code (Work).all;
            Info : Landin.Debugging.Information (Landin.Stages.Trees (Work));
            Routine, Datum : IR.Item_Id := IR.No_Item;
            Slot : IR.Slot_Id := IR.No_Slot;

            function Symbol (Id : IR.Item_Id) return String;

            function Symbol (Id : IR.Item_Id) return String is
              ("item_" & Ada.Strings.Fixed.Trim
                 (Id'Image, Ada.Strings.Both));
         begin
            for Index in 1 .. IR.Item_Count (Unit) loop
               if IR.Kind_Of (Unit, IR.Item_Id (Index)) = IR.Routine then
                  Routine := IR.Item_Id (Index);
               else
                  Datum := IR.Item_Id (Index);
               end if;
            end loop;
            for Index in 1 .. IR.Slot_Count (Unit, Routine) loop
               declare
                  Binding : constant IR.Declaration_Id :=
                    IR.Declares (Unit, Routine, IR.Slot_Id (Index));
               begin
                  if Binding /= IR.No_Declaration
                    and then Landin.Source.Names.Spelling
                      (Landin.Stages.Identities (Work).all,
                       Landin.Resolution.Name_Of
                         (Landin.Stages.Meanings (Work).all, Binding))
                      = "local"
                  then
                     Slot := IR.Slot_Id (Index);
                  end if;
               end;
            end loop;
            Landin.Testing.Check
              (Item, Slot /= IR.No_Slot and then Datum /= IR.No_Item,
               "the tiny alias seam has both local and module storage");
            if Slot = IR.No_Slot or else Datum = IR.No_Item then
               return;
            end if;
            IR.Note_Source_Alias
              (Unit, Routine,
               (Binding => IR.Declares (Unit, Routine, Slot),
                Site => IR.Origin_Of (Unit, Routine, Slot),
                Place => (if From_Module
                          then (Kind => IR.Module_Datum, Datum => Datum)
                          else (Kind => IR.Frame_Slot, Slot => Slot)),
                Field => 0, Initialized_On_Entry => True), IR.No_Path_Steps);
            Landin.Debugging.Append (Info, Landin.Stages.Source (Work, 1));
            declare
               Sections : US.Unbounded_String;
            begin
               Sections := US.To_Unbounded_String
                 (Landin.Backend.X86_64.Dwarf.Sections
                    (Unit, Landin.Stages.Meanings (Work).all,
                     Landin.Stages.Identities (Work).all,
                     Landin.Targets.Linux_X86_64,
                     Landin.Optimization.Default_Options,
                     Info, ".Lalias_", Symbol'Access));
               Landin.Testing.Check
                 (Item, Array_Storage and then Contains
                    (US.To_String (Sections), "debug_alias_loc"),
                  "whole array aliases have a serialized location");
            exception
               when Error : Landin.Compiler_Defect =>
                  Landin.Testing.Check
                    (Item, not Array_Storage and then
                       Ada.Exceptions.Exception_Message (Error) = Expected,
                     "a non-array whole alias fails before a shape query");
            end;
         end;
      end Check;
   begin
      Check (False, False);
      Check (True, False);
      Check (False, True);
      Check (True, True);
   end Whole_Aliases_Require_Array_Storage;

   procedure Array_Addresses_Keep_Homes
     (Item : in out Landin.Testing.Context);

   procedure Array_Addresses_Keep_Homes
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List := Request;
   begin
      Host.Add_File
        ("main.ldn", "public main: () -> (code: i32) = "
         & "local: [1]i32 = [42] copy: [1]i32 = local "
         & "code = copy[0] end main");
      Args.Append ("--debug=full");
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, 0, "small frame array addresses emit");
         Landin.Testing.Check
           (Item, Contains (Host.Written ("out.s"), "leaq")
              and then Contains (Host.Written ("out.s"), ".debug_info")
              and then Tools.Run_Count = 0,
            "address and debug output is text in the fake filesystem");
      end;
   end Array_Addresses_Keep_Homes;

   procedure Terminal_Locations_Stop_Before_Restores
     (Item : in out Landin.Testing.Context);

   procedure Terminal_Locations_Stop_Before_Restores
     (Item : in out Landin.Testing.Context)
   is
      package Dwarf renames Landin.Backend.X86_64.Dwarf;
      Result_Source : constant String :=
        "public main: () -> (code: i32) = code = 42 end main";
      HT : constant Character := Character'Val (9);

      procedure Check
        (Text : String; Expected : Natural; On_Failure : Boolean := True);

      procedure Check
        (Text : String; Expected : Natural; On_Failure : Boolean := True)
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      begin
         Lower (Item, Work, Text);
         if Landin.Stages.Failed (Work) then
            return;
         end if;
         declare
            Unit : IR.Unit renames Landin.Stages.Code (Work).all;
            Info : Landin.Debugging.Information (Landin.Stages.Trees (Work));
            Routine : IR.Item_Id := IR.No_Item;
            Slot : IR.Slot_Id := IR.No_Slot;
            Terminals : Natural := 0;

            function Symbol (Id : IR.Item_Id) return String;

            function Symbol (Id : IR.Item_Id) return String is
              ("item_" & Ada.Strings.Fixed.Trim
                 (Id'Image, Ada.Strings.Both));
         begin
            for Index in 1 .. IR.Item_Count (Unit) loop
               if IR.Kind_Of (Unit, IR.Item_Id (Index)) = IR.Routine then
                  Routine := IR.Item_Id (Index);
               end if;
            end loop;
            for Index in 1 .. IR.Slot_Count (Unit, Routine) loop
               declare
                  Binding : constant IR.Declaration_Id :=
                    IR.Declares (Unit, Routine, IR.Slot_Id (Index));
               begin
                  if Binding /= IR.No_Declaration
                    and then Landin.Source.Names.Spelling
                      (Landin.Stages.Identities (Work).all,
                       Landin.Resolution.Name_Of
                         (Landin.Stages.Meanings (Work).all, Binding))
                      = "code"
                  then
                     Slot := IR.Slot_Id (Index);
                  end if;
               end;
            end loop;
            Landin.Testing.Check
              (Item, Slot /= IR.No_Slot, "the named result has storage");
            if Slot = IR.No_Slot then
               return;
            end if;
            Landin.Debugging.Append (Info, Landin.Stages.Source (Work, 1));
            declare
               Live : constant Landin.Backend.Debug_Locations.Flags.Vector :=
                 Landin.Backend.Debug_Locations.Available
                   (Unit, Landin.Stages.Meanings (Work).all,
                    Info, Routine, Slot, False);
               Sections : constant String := Dwarf.Sections
                 (Unit, Landin.Stages.Meanings (Work).all,
                  Landin.Stages.Identities (Work).all,
                  Landin.Targets.Linux_X86_64,
                  Landin.Optimization.Default_Options,
                  Info, ".Lterminal_", Symbol'Access);
            begin
               for Index in 1 .. IR.Value_Count (Unit, Routine) loop
                  if IR.Op_Of (Unit, Routine, IR.Value_Id (Index))
                    in IR.Leave | IR.Fail
                  then
                     Terminals := Terminals + 1;
                     Landin.Testing.Check
                       (Item, Live (Index) =
                          (IR.Op_Of (Unit, Routine, IR.Value_Id (Index))
                             = IR.Leave or else On_Failure),
                        "terminal availability requires initialization");
                     Landin.Testing.Check
                       (Item, Contains (Sections, HT & ".quad "
                          & Dwarf.Label_Name
                            (".Lterminal_", "epilogue", Routine, Index) & LF),
                        "each terminal range ends before register restores");
                  end if;
               end loop;
            end;
            for Index in 1 .. IR.Parameter_Count (Unit, Routine) loop
               declare
                  Live : constant
                    Landin.Backend.Debug_Locations.Flags.Vector :=
                      Landin.Backend.Debug_Locations.Available
                        (Unit, Landin.Stages.Meanings (Work).all,
                         Info, Routine,
                         IR.Nth_Parameter (Unit, Routine, Index), True);
               begin
                  for V in 1 .. IR.Value_Count (Unit, Routine) loop
                     if IR.Op_Of (Unit, Routine, IR.Value_Id (V))
                       in IR.Leave | IR.Fail
                     then
                        Landin.Testing.Check
                          (Item, Live (V),
                           "parameters remain available at terminals");
                     end if;
                  end loop;
               end;
            end loop;
            Landin.Testing.Check_Equal
              (Item, Terminals, Expected, "all terminal paths were inspected");
         end;
      end Check;
   begin
      Check (Result_Source, 1);
      Check ("f: (flag: bool) -> (code: i32) = code = 42 "
         & "return when flag code = 7 end f", 2);
      Check ("problem: atom f: (flag: bool) -> (code: i32) ! problem = "
         & "code = 42 fail problem when flag end f", 2);
      Check ("problem: atom f: (flag: bool) -> (code: i32) ! problem = "
         & "fail problem when flag code = 42 end f", 2, False);
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List := Request;
      begin
         Host.Add_File ("main.ldn", Result_Source);
         Args.Append ("--debug=full");
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Host, Tools);
            Assembly : constant String := Host.Written ("out.s");
            First : constant Natural :=
              Ada.Strings.Fixed.Index (Assembly, ".Ldebug_epilogue_");
         begin
            Landin.Testing.Check
              (Item, Result.Status = 0 and then Tools.Run_Count = 0
                 and then First > 0,
               "full debug emits a terminal boundary without host tools");
            if First > 0 then
               declare
                  Last : constant Natural := Ada.Strings.Fixed.Index
                    (Assembly, ":" & LF, From => First);
                  Label : constant String := Assembly (First .. Last - 1);
               begin
                  Landin.Testing.Check
                    (Item, Contains
                       (Assembly, Label & ":" & LF
                        & HT & ".cfi_remember_state" & LF)
                       and then Contains (Assembly, ".quad " & Label & LF),
                     "location references use the pre-restore code boundary");
               end;
            end if;
         end;
      end;
   end Terminal_Locations_Stop_Before_Restores;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "debugging", "terminal locations stop before restores",
         Terminal_Locations_Stop_Before_Restores'Access);
      Landin.Testing.Register
        (Into, "debugging", "register locations preserve indirection",
         Register_Locations_Preserve_Indirection'Access);
      Landin.Testing.Register
        (Into, "debugging", "whole aliases require array storage",
         Whole_Aliases_Require_Array_Storage'Access);
      Landin.Testing.Register
        (Into, "debugging", "array addresses keep homes",
         Array_Addresses_Keep_Homes'Access);
      Landin.Testing.Register
        (Into, "debugging", "invalid debug requests and help",
         Invalid_Requests'Access);
      Landin.Testing.Register
        (Into, "debugging", "none default and independent build modes",
         Defaults'Access);
      Landin.Testing.Register
        (Into, "debugging", "caller-only and complete source identities",
         Source_Maps'Access);
      Landin.Testing.Register
        (Into, "debugging", "GNU filename byte quoting", Path_Bytes'Access);
      Landin.Testing.Register
        (Into, "debugging", "aggregate fieldwise initialization and joins",
         Fieldwise'Access);
      Landin.Testing.Register
        (Into, "debugging", "stored direct indirect and copied results",
         Stored_Returns'Access);
      Landin.Testing.Register
        (Into, "debugging", "scalar initialization and lexical scopes",
         Scopes'Access);
      Landin.Testing.Register
        (Into, "debugging", "loop reentry resets initialization",
         Loops'Access);
      Landin.Testing.Register
        (Into, "debugging", "nested array fields and rooted copies",
         Arrays'Access);
      Landin.Testing.Register
        (Into, "debugging", "stored results follow only success edges",
         Failing_Returns'Access);
      Landin.Testing.Register
        (Into, "debugging", "named result and destructuring leaf availability",
         Aliases'Access);
   end Register;
end Landin.Tests.Debugging_Suite;
