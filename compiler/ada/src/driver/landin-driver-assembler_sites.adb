with Ada.Strings.Fixed;

with Landin.Backend;
with Landin.Diagnostics.Catalogue;
with Landin.Provenance;

package body Landin.Driver.Assembler_Sites is

   use type Landin.IR.Opcode;
   use type Landin.Provenance.Origin;

   LF : constant Character := Character'Val (10);

   --  Text without blanks or tabs at either end; an assembler line is
   --  indented with a tab.
   function Trimmed (Text : String) return String;

   function Trimmed (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last and then Text (First) in ' ' | ASCII.HT loop
         First := First + 1;
      end loop;
      while Last >= First and then Text (Last) in ' ' | ASCII.HT loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trimmed;

   --  Line Number of Text, from one, without its line end, or "" past its
   --  last line.
   function Line_Of (Text : String; Number : Positive) return String;

   function Line_Of (Text : String; Number : Positive) return String is
      Seen  : Positive := 1;
      First : Natural := Text'First;
   begin
      for Index in Text'Range loop
         if Seen = Number then
            First := Index;
            exit;
         end if;
         if Text (Index) = LF then
            Seen := Seen + 1;
         end if;
      end loop;
      if Seen /= Number then
         return "";
      end if;
      for Index in First .. Text'Last loop
         if Text (Index) = LF then
            return Text (First .. Index - 1);
         end if;
      end loop;
      return Text (First .. Text'Last);
   end Line_Of;

   --  The line number in an assembler message `name.s:N: rest`, or 0, and
   --  where the rest begins.
   procedure Read_Message
     (Message : String; Number : out Natural; Rest : out Natural);

   procedure Read_Message
     (Message : String; Number : out Natural; Rest : out Natural)
   is
      Colon : constant Natural := Ada.Strings.Fixed.Index (Message, ".s:");
      Digit : Natural;
   begin
      Number := 0;
      Rest := 0;
      if Colon = 0 then
         return;
      end if;
      Digit := Colon + 3;
      while Digit <= Message'Last
        and then Message (Digit) in '0' .. '9'
      loop
         Number := Number * 10
           + (Character'Pos (Message (Digit)) - Character'Pos ('0'));
         Digit := Digit + 1;
      end loop;
      if Digit <= Message'Last and then Message (Digit) = ':' then
         Rest := Digit + 1;
      else
         Number := 0;
      end if;
   end Read_Message;

   --  The block whose text holds Instruction, written once in the whole
   --  program, or No_Origin when none does or more than one does.
   function Block_Writing
     (Instruction : String;
      Code        : Landin.IR.Unit;
      Names       : Landin.Source.Names.Table;
      Facts       : Landin.Targets.Target_Facts)
      return Landin.Provenance.Origin;

   function Block_Writing
     (Instruction : String;
      Code        : Landin.IR.Unit;
      Names       : Landin.Source.Names.Table;
      Facts       : Landin.Targets.Target_Facts)
      return Landin.Provenance.Origin
   is
      Found : Landin.Provenance.Origin := Landin.Provenance.No_Origin;
      Count : Natural := 0;
   begin
      for Item in 1 .. Landin.IR.Item_Count (Code) loop
         declare
            Id : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Item);
         begin
            for Value in 1 .. Landin.IR.Value_Count (Code, Id) loop
               declare
                  At_Value : constant Landin.IR.Value_Id :=
                    Landin.IR.Value_Id (Value);
               begin
                  if Landin.IR.Op_Of (Code, Id, At_Value)
                       = Landin.IR.Assembly
                  then
                     declare
                        Text : constant String :=
                          Landin.Backend.Assembly_Text
                            (Code, Id, At_Value, Names, Facts);
                        Start : Natural := Text'First;
                     begin
                        for Index in Text'First .. Text'Last + 1 loop
                           if Index > Text'Last or else Text (Index) = LF
                           then
                              if Trimmed (Text (Start .. Index - 1))
                                = Instruction
                              then
                                 Count := Count + 1;
                                 Found := Landin.IR.Origin_Of
                                   (Code, Id, At_Value);
                              end if;
                              Start := Index + 1;
                           end if;
                        end loop;
                     end;
                  end if;
               end;
            end loop;
         end;
      end loop;
      return (if Count = 1 then Found else Landin.Provenance.No_Origin);
   end Block_Writing;

   procedure Place
     (Output  : String;
      Emitted : String;
      Code    : Landin.IR.Unit;
      Names   : Landin.Source.Names.Table;
      Facts   : Landin.Targets.Target_Facts;
      Into    : in out Landin.Diagnostics.Diagnostic_List;
      Placed  : out Boolean)
   is
      Pending : Landin.Diagnostics.Diagnostic_List;
      Start   : Natural := Output'First;
   begin
      Placed := False;
      for Index in Output'First .. Output'Last + 1 loop
         if Index > Output'Last or else Output (Index) = LF then
            declare
               Message : constant String := Output (Start .. Index - 1);
               Number, Rest : Natural;
            begin
               Read_Message (Message, Number, Rest);
               if Number > 0 then
                  declare
                     Origin : constant Landin.Provenance.Origin :=
                       Block_Writing
                         (Trimmed (Line_Of (Emitted, Number)),
                          Code, Names, Facts);
                  begin
                     --  A line nothing places makes the whole output the
                     --  tool's, as it stands.
                     if Origin = Landin.Provenance.No_Origin then
                        return;
                     end if;
                     Pending.Append
                       (Landin.Diagnostics.Make
                          (Code    => Landin.Diagnostics.Catalogue.Code
                             (Landin.Diagnostics.Catalogue.Toolchain_Failed),
                           Level   => Landin.Diagnostics.Error,
                           Source  => Origin.Source,
                           Where   => Origin.Where,
                           Message => "the assembler refused this block's `"
                             & Trimmed (Line_Of (Emitted, Number)) & "`: "
                             & Trimmed (Message (Rest .. Message'Last))));
                  end;
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      if Landin.Diagnostics.Count (Pending) = 0 then
         return;
      end if;
      for Index in 1 .. Landin.Diagnostics.Count (Pending) loop
         Into.Append (Landin.Diagnostics.Get (Pending, Index));
      end loop;
      Placed := True;
   end Place;

end Landin.Driver.Assembler_Sites;
