with Ada.Strings.Fixed;
with Landin.Backend.Debug_Locations;
with Landin.Backend.Dwarf;

package body Landin.Backend.X86_64.Dwarf is
   use Landin.IR;
   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);
   use type Allocation.Location_Kind;
   use type Allocation.Register_Id;
   use type Allocation.SSE_Register;
   function N (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Quoted (Bytes : String) return String
     renames Landin.Backend.Dwarf.Quoted;
   function Label_Name
     (Prefix, Kind : String; Item : Item_Id;
      Index : Natural := 0) return String
     renames Landin.Backend.Dwarf.Label_Name;

   function Register_Number
     (Register : Allocation.General_Register) return Natural
   is (case Register is
          when Allocation.RBX => 3,
          when Allocation.RSI => 4,
          when Allocation.RDI => 5,
          when Allocation.R8 => 8,
          when Allocation.R9 => 9,
          when Allocation.R12 => 12,
          when Allocation.R13 => 13,
          when Allocation.R14 => 14,
          when Allocation.R15 => 15);

   function Register_Location
     (Register : Allocation.General_Register; Indirect : Boolean)
      return String
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
   --  includes everything before its last position.  The register still
   --  holds the slot's value after that position, through the rest of
   --  its block, until a value writes it: that value is the Overwriter,
   --  and the encoder describes the slot at its first address too.  The
   --  next block may be entered from elsewhere, where the register is
   --  already another location's.
   procedure Narrow
     (Of_Unit : Unit; Item : Item_Id; Plan : Allocation.Plan;
      Slot : Slot_Id;
      Live : in out Landin.Backend.Debug_Locations.Flags.Vector;
      Overwriter : in out Value_Id);

   procedure Narrow
     (Of_Unit : Unit; Item : Item_Id; Plan : Allocation.Plan;
      Slot : Slot_Id;
      Live : in out Landin.Backend.Debug_Locations.Flags.Vector;
      Overwriter : in out Value_Id)
   is
      Place : constant Allocation.Location := Plan.Slot (Positive (Slot));
      Opened : Boolean := Place.From = No_Value;
      Closed : Boolean := False;
      --  Whether the interval has closed in this block and nothing has
      --  written the register since.  Only selection's own discipline
      --  promises that: a callee-saved register outlives every call, an
      --  XMM register any operation but a call, and a caller-saved one
      --  any operation but those Allocation.Touches names.
      Keeps : constant Boolean := Place.Kind in Allocation.SSE | Allocation.GP;
      Holding : Boolean := False;

      function Same (Other : Allocation.Location) return Boolean is
        (Other.Kind = Place.Kind
         and then (if Place.Kind = Allocation.SSE
                   then Other.Float_Register = Place.Float_Register
                   else Other.Register = Place.Register));

      --  Whether Value is the slot's own bits: a load of it, or the
      --  address a loaded pointer holds.
      function Copies (Value : Value_Id) return Boolean is
        ((Op_Of (Of_Unit, Item, Value) = Load
          and then Slot_Of (Of_Unit, Item, Value) = Slot)
         or else
           (Op_Of (Of_Unit, Item, Value) = Pointer_Address
            and then Op_Of
              (Of_Unit, Item, Nth_Operand (Of_Unit, Item, Value, 1)) = Load
            and then Slot_Of
              (Of_Unit, Item, Nth_Operand (Of_Unit, Item, Value, 1))
              = Slot));

      --  Whether Value writes the slot's register: as its own location,
      --  unless it copies the slot, by storing to another slot held
      --  there, as assembly, which may name any register, for an XMM
      --  register by calling, or for a caller-saved one as selection's
      --  own scratch.
      function Writes (Value : Value_Id) return Boolean is
        (Op_Of (Of_Unit, Item, Value) = Assembly
         or else (Place.Kind = Allocation.SSE
                  and then Op_Of (Of_Unit, Item, Value)
                    in Call | Indirect_Call)
         or else (Place.Kind = Allocation.GP
                  and then Place.Register in Allocation.Caller_Saved
                  and then Allocation.Touches
                    (Of_Unit, Item, Value, Place.Register))
         or else (Same (Plan.Value (Positive (Value)))
                  and then not Copies (Value))
         or else (Op_Of (Of_Unit, Item, Value) = Store
                  and then Same (Plan.Slot
                    (Positive (Slot_Of (Of_Unit, Item, Value))))));
   begin
      if Place.From = No_Value and then Place.Through = No_Value then
         return;
      end if;
      for Block in 1 .. Block_Count (Of_Unit, Item) loop
         Holding := False;
         for Position in 1 .. Length (Of_Unit, Item, Block_Id (Block)) loop
            declare
               Value : constant Value_Id :=
                 Nth_Value (Of_Unit, Item, Block_Id (Block), Position);
            begin
               if Opened and then not Closed then
                  Closed := Value = Place.Through;
                  Holding := Closed and then Keeps;
               elsif Holding and then not Writes (Value) then
                  null;
               else
                  if Holding and then Live (Positive (Value)) then
                     Overwriter := Value;
                  end if;
                  Holding := False;
                  Live (Positive (Value)) := False;
                  if Value = Place.From then
                     Opened := True;
                     Closed := Place.From = Place.Through;
                     Holding := Closed and then Keeps;
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
