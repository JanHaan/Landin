with Ada.Strings.Fixed;
with Landin.Backend.Debug_Locations;
with Landin.Backend.Dwarf;

package body Landin.Backend.X86_64.Dwarf is
   use Landin.IR;
   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);
   use type Allocation.Location_Kind;
   function N (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Quoted (Bytes : String) return String
     renames Landin.Backend.Dwarf.Quoted;
   function Label_Name
     (Prefix, Kind : String; Item : Item_Id;
      Index : Natural := 0) return String
     renames Landin.Backend.Dwarf.Label_Name;

   function Register_Number
     (Register : Allocation.Saved_Register) return Natural
   is (case Register is
          when Allocation.RBX => 3,
          when Allocation.R12 => 12,
          when Allocation.R13 => 13,
          when Allocation.R14 => 14,
          when Allocation.R15 => 15);

   function Register_Location
     (Register : Allocation.Saved_Register; Indirect : Boolean) return String
   is
     (HT & ".byte " & N ((if Indirect then 16#70# else 16#50#)
                        + Register_Number (Register)) & LF
      & (if Indirect then HT & ".sleb128 0" & LF else ""));

   function Source_Line
     (Info : Landin.Debugging.Information;
      Site : Landin.Provenance.Origin) return String
      renames Landin.Backend.Dwarf.Source_Line;

   function Preamble
     (Info : Landin.Debugging.Information; Prefix : String) return String is
     (Landin.Backend.Dwarf.Preamble (Info, Prefix));

   function Frame_For
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts; Plan : Allocation.Plan;
      Options : Landin.Optimization.Options) return Frame is
     (Allocation.Frame_For (Of_Unit, Item, Facts, Plan, Options));

   function Slot_Expression
     (Plan : Allocation.Plan; Layout : Frame; Slot : Landin.IR.Slot_Id;
      Indirect, Address_Only : Boolean) return String;

   function Slot_Expression
     (Plan : Allocation.Plan; Layout : Frame; Slot : Landin.IR.Slot_Id;
      Indirect, Address_Only : Boolean) return String
   is
      Place : constant Allocation.Location := Plan.Slot (Positive (Slot));
   begin
      if Place.Kind = Allocation.GP and then
        (Indirect or else not Address_Only)
      then
         return Register_Location (Place.Register, Indirect);
      elsif Place.Kind = Allocation.SSE
        and then not Indirect and then not Address_Only
      then
         --  DWARF's x86-64 register numbers 17..32 name XMM0..XMM15.
         return HT & ".byte " & N (16#50# + 25
           + Allocation.SSE_Register'Pos (Place.Float_Register)) & LF;
      elsif Has_Slot_Home (Layout, Slot) then
         return HT & ".byte 0x91" & LF & HT & ".sleb128 -"
           & Ada.Strings.Fixed.Trim (Landin.Targets.Byte_Count'Image
               (Slot_Offset (Layout, Slot)), Ada.Strings.Both) & LF
           & (if Indirect then HT & ".byte 0x06" & LF else "");
      end if;
      return "";
   end Slot_Expression;

   --  A slot the plan holds in a register only over an interval of the
   --  routine, in the order its blocks are laid out, is there nowhere
   --  else: the register belongs to other locations before and after.
   --  An interval opening at a store excludes that store's own
   --  instruction, which precedes the write; one open from the entry
   --  includes everything before its last position.
   procedure Narrow
     (Of_Unit : Unit; Item : Item_Id; Plan : Allocation.Plan;
      Slot : Slot_Id;
      Live : in out Landin.Backend.Debug_Locations.Flags.Vector);

   procedure Narrow
     (Of_Unit : Unit; Item : Item_Id; Plan : Allocation.Plan;
      Slot : Slot_Id;
      Live : in out Landin.Backend.Debug_Locations.Flags.Vector)
   is
      Place : constant Allocation.Location := Plan.Slot (Positive (Slot));
      Opened : Boolean := Place.From = No_Value;
      Closed : Boolean := False;
   begin
      if Place.From = No_Value and then Place.Through = No_Value then
         return;
      end if;
      for Block in 1 .. Block_Count (Of_Unit, Item) loop
         for Position in 1 .. Length (Of_Unit, Item, Block_Id (Block)) loop
            declare
               Value : constant Value_Id :=
                 Nth_Value (Of_Unit, Item, Block_Id (Block), Position);
            begin
               if Opened and then not Closed then
                  Closed := Value = Place.Through;
               else
                  Live (Positive (Value)) := False;
                  if Value = Place.From then
                     Opened := True;
                     Closed := Place.From = Place.Through;
                  end if;
               end if;
            end;
         end loop;
      end loop;
   end Narrow;

   function Encode is new Landin.Backend.Dwarf.Sections
     (Allocation.Plan, Plan_Access, Frame_Access,
      Allocation.Make, Frame_For, Slot_Expression, 6, False,
      Narrow => Narrow);

   function Sections
     (Of_Unit : Unit;
      Meanings : Landin.Resolution.Table;
      Names : Landin.Source.Names.Table;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Info : Landin.Debugging.Information;
      Prefix : String;
      Symbol : not null access function (Item : Item_Id) return String;
      Cached_Plan : access function
        (Item : Item_Id) return Plan_Access := null;
      Cached_Frame : access function (Item : Item_Id)
        return Frame_Access := null;
      Trapped : access function
        (Item : Item_Id; Value : Value_Id) return Boolean := null)
      return String
      renames Encode;

end Landin.Backend.X86_64.Dwarf;
