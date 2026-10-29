with Ada.Strings.Unbounded;
with Ada.Containers.Vectors;
with Ada.Containers.Ordered_Maps;
with Ada.Strings.Fixed;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets.Capabilities;
with Landin.Targets.Layouts;
with Landin.Types;
with Landin.Layouts;
with Landin.IR.Shape_Measurement;

package body Landin.Backend.Dwarf is

   package US renames Ada.Strings.Unbounded;
   use Landin.IR;
   use type Landin.Layouts.Policy;
   use type Landin.IR.Declaration_Id;
   use type Landin.IR.Nominal_Type_Id;
   use type Landin.IR.Scope_Id;
   use type Landin.Resolution.Scope_Sort;
   use type Landin.Source.Source_Id;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Targets.Byte_Count;
   use type Landin.Types.Type_Kind;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   function N (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Quoted (Bytes : String) return String is
      Result : US.Unbounded_String := US.To_Unbounded_String ("""");
      Octal : constant String := "01234567";
   begin
      for Byte of Bytes loop
         if Byte in '"' | '\' then
            US.Append (Result, '\');
            US.Append (Result, Byte);
         elsif Character'Pos (Byte) in 32 .. 126 then
            US.Append (Result, Byte);
         else
            declare
               Value : constant Natural := Character'Pos (Byte);
            begin
               US.Append (Result, '\');
               US.Append (Result, Octal (Value / 64 + 1));
               US.Append (Result, Octal (Value / 8 mod 8 + 1));
               US.Append (Result, Octal (Value mod 8 + 1));
            end;
         end if;
      end loop;
      US.Append (Result, '"');
      return US.To_String (Result);
   end Quoted;

   function Label_Name
     (Prefix, Kind : String; Item : Item_Id;
      Index : Natural := 0) return String
   is (Prefix & "debug_" & Kind & "_" & N (Natural (Item)) & "_"
       & N (Index));

   function Source_Line
     (Info : Landin.Debugging.Information;
      Site : Landin.Provenance.Origin) return String
   is
   begin
      if not Landin.Provenance.Is_Known (Site) then
         return "";
      end if;
      declare
         Pos : constant Landin.Source.Position := Landin.Source.Position_Of
           (Landin.Debugging.Source (Info, Site.Source), Site.Where.First);
      begin
         return HT & ".loc " & N (Natural (Site.Source)) & " "
           & N (Natural (Pos.Line)) & " " & N (Natural (Pos.Column));
      end;
   end Source_Line;

   function Section
     (Name : String; Mach_O : Boolean; Arm : Boolean := False)
      return String is
     (HT & (if Mach_O then ".section __DWARF,__debug_" & Name
              & ",regular,debug"
            else ".section .debug_" & Name & ","""","
              & (if Arm then "%" else "@") & "progbits"));

   function Preamble
     (Info : Landin.Debugging.Information; Prefix : String;
      Mach_O : Boolean := False; Arm : Boolean := False) return String
   is
      Result : US.Unbounded_String;
   begin
      if not Mach_O then
         US.Append (Result, HT & ".cfi_sections .debug_frame" & LF);
      end if;
      if not Arm then
         US.Append (Result, Section ("line", Mach_O) & LF);
         US.Append (Result, Prefix & "debug_line:" & LF & HT & ".text" & LF);
      end if;
      if Mach_O then
         US.Append (Result, Prefix & "debug_text:" & LF);
      end if;
      for Index in 1 .. Landin.Debugging.Count (Info) loop
         US.Append (Result, HT & ".file " & N (Index) & " "
           & Quoted (Landin.Debugging.Recorded_Name
               (Info, Landin.Source.Source_Id (Index))) & LF);
      end loop;
      return US.To_String (Result);
   end Preamble;

   function Line_Sections
     (Of_Unit : Unit;
      Meanings : Landin.Resolution.Table;
      Names : Landin.Source.Names.Table;
      Facts : Landin.Targets.Target_Facts;
      Info : Landin.Debugging.Information;
      Prefix : String;
      Symbol : not null access function (Item : Item_Id) return String)
      return String
   is
      Result : US.Unbounded_String;
      CU : constant String := Prefix & "debug_info";
      Width : constant Positive := Landin.Targets.Bytes
        (Landin.Targets.Pointer_Size (Facts));
      Address : constant String := (if Width = 4 then ".long " else ".quad ");
      procedure Put (Text : String);
      procedure Put (Text : String) is
      begin
         US.Append (Result, Text & LF);
      end Put;
   begin
      --  Declare ARM debug sections after all loadable input sections. GNU
      --  ld's veneer ordering depends on input section identities.
      Put (Section ("line", False, Arm => True));
      Put (Prefix & "debug_line:");
      Put (Section ("abbrev", False, Arm => True));
      Put (Prefix & "debug_abbrev:");
      Put (HT & ".uleb128 1,0x11,1");
      Put (HT & ".uleb128 0x25,0x08,0x13,0x05,0x03,0x08,"
        & "0x1b,0x08,0x10,0x17,0,0");
      Put (HT & ".uleb128 2,0x2e,0");
      Put (HT & ".uleb128 0x03,0x08,0x11,0x01,0x12,0x01,"
        & "0x3a,0x0f,0x3b,0x0f,0x39,0x0f,0,0,0");
      Put (Section ("info", False, Arm => True));
      Put (CU & ":");
      Put (HT & ".long " & CU & "_end-" & CU & "-4");
      Put (HT & ".short 4");
      Put (HT & ".long " & Prefix & "debug_abbrev");
      Put (HT & ".byte " & N (Width));
      Put (HT & ".uleb128 1");
      Put (HT & ".asciz ""Landin refine (lines)""");
      Put (HT & ".short 0x0002");
      Put (HT & ".asciz " & Quoted
        (Landin.Debugging.Recorded_Name (Info, 1)));
      Put (HT & ".asciz " & Quoted (Landin.Debugging.Directory (Info)));
      Put (HT & ".long " & Prefix & "debug_line");
      for Index in 1 .. Item_Count (Of_Unit) loop
         declare
            Item : constant Item_Id := Item_Id (Index);
            Decl : constant Declaration_Id :=
              (if Generic_Template_Of (Of_Unit, Item) /= No_Declaration
               then Generic_Template_Of (Of_Unit, Item)
               else Declares (Of_Unit, Item));
         begin
            if Kind_Of (Of_Unit, Item) = Landin.IR.Routine
              and then not Is_External (Of_Unit, Item)
            then
               declare
                  Site : constant Landin.Provenance.Origin :=
                    Origin_Of (Of_Unit, Item);
                  Pos : constant Landin.Source.Position :=
                    Landin.Source.Position_Of
                      (Landin.Debugging.Source (Info, Site.Source),
                       Site.Where.First);
               begin
                  Put (HT & ".uleb128 2");
                  Put (HT & ".asciz " & Quoted
                    (if Decl = No_Declaration then Symbol (Item)
                     else Landin.Source.Names.Spelling
                       (Names, Landin.Resolution.Name_Of (Meanings, Decl))));
                  Put (HT & Address & Label_Name (Prefix, "begin", Item));
                  Put (HT & Address & Label_Name (Prefix, "end", Item));
                  Put (HT & ".uleb128 " & N (Natural (Site.Source)) & ","
                    & N (Natural (Pos.Line)) & ","
                    & N (Natural (Pos.Column)));
               end;
            end if;
         end;
      end loop;
      Put (HT & ".uleb128 0");
      Put (CU & "_end:");
      return US.To_String (Result);
   end Line_Sections;

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
        (Item : Item_Id) return Placement_Access := null;
      Cached_Frame : access function
        (Item : Item_Id) return Frame_Access := null;
      Trapped : access function
        (Item : Item_Id; Value : Value_Id) return Boolean := null)
      return String
   is
      Result, Locations, Ranges : US.Unbounded_String;
      CU : constant String := Prefix & "debug_info";
      type Description is record
         Shape : Field_Shape;
         Source : Landin.Source.Source_Id := Landin.Source.No_Source;
         Node : Landin.Syntax.Node_Id := Landin.Syntax.No_Node;
         Item : Item_Id := No_Item;
         Slot : Slot_Id := No_Slot;
      end record;
      package Descriptions is new Ada.Containers.Vectors
        (Positive, Description);
      Types : Descriptions.Vector;
      Type_Layouts : Landin.IR.Shape_Measurement.Layout_Cache;
      --  The code each atom has in this program, which D423's enumerators
      --  give it.
      Codes : constant Atom_Codes := Ranked (Of_Unit);

      --  A module datum's location expression: DW_OP_addr and its symbol,
      --  or D496's instance of the selected thread, its offset in the
      --  thread's block and DW_OP_form_tls_address.  Empty for a thread's
      --  instance on arm64 ELF, whose assemblers spell no DTP-relative
      --  word, where the datum then has no location, as GCC leaves it.
      function Datum_Expression (Item : Item_Id) return String;
      function Datum_Expression (Item : Item_Id) return String is
         use type Landin.Targets.Capabilities.Backend_Kind;
         Backend : constant Landin.Targets.Capabilities.Backend_Kind :=
           Landin.Targets.Capabilities.Backend_For (Facts);
      begin
         if not Landin.Backend.In_Thread_Storage (Of_Unit, Facts, Item) then
            return HT & ".byte 0x03" & LF & HT & ".quad " & Symbol (Item)
              & LF;
         elsif Backend = Landin.Targets.Capabilities.X86_64_ELF then
            return HT & ".byte 0x0e" & LF & HT & ".long " & Symbol (Item)
              & "@dtpoff, 0" & LF & HT & ".byte 0x9b" & LF;
         elsif Backend = Landin.Targets.Capabilities.RV64_ELF then
            return HT & ".byte 0x0e" & LF & HT & ".dtpreldword "
              & Symbol (Item) & LF & HT & ".byte 0x9b" & LF;
         elsif Backend = Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
         then
            --  The thread-local variable's descriptor, which LLDB hands
            --  to the loader for the selected thread's instance.
            return HT & ".byte 0x0e" & LF & HT & ".quad " & Symbol (Item)
              & LF & HT & ".byte 0x9b" & LF;
         else
            return "";
         end if;
      end Datum_Expression;

      procedure Put (Text : String);
      procedure Put (Text : String) is
      begin
         US.Append (Result, Text & LF);
      end Put;

      procedure U (Value : Natural);
      procedure U (Value : Natural) is
      begin
         Put (HT & ".uleb128 " & N (Value));
      end U;

      procedure Ref (Name : String);
      procedure Ref (Name : String) is
      begin
         Put (HT & ".long " & Name & "-" & CU);
      end Ref;

      procedure Str (Text : String);
      procedure Str (Text : String) is
      begin
         Put (HT & ".asciz " & Quoted (Text));
      end Str;

      function L (Kind : String; Item : Item_Id; Index : Natural := 0)
         return String is (Label_Name (Prefix, Kind, Item, Index));
      function T (Index : Positive) return String is
        (Prefix & "debug_type_" & N (Index));
      function Decl_Name (Decl : Declaration_Id) return String is
        (Landin.Source.Names.Spelling
           (Names, Landin.Resolution.Name_Of (Meanings, Decl)));

      --  [0480]/[1870]: a union of several atoms and one pointer has no
      --  template; it is presented as a structure named by its canonical
      --  source spelling, whose members are `atom` and `ptr`.
      function Is_Union (Nominal : Nominal_Type_Id) return Boolean is
        (Nominal /= No_Nominal_Type
         and then Is_Pointer_Union (Of_Unit, Nominal));

      function Nominal_Name (Nominal : Nominal_Type_Id) return String is
        (if Is_Union (Nominal)
         then Landin.Source.Names.Spelling
           (Names, Union_Spelling (Of_Unit, Nominal))
         else Decl_Name (Template_Of (Of_Unit, Nominal)));

      function Intern (Input : Description) return Positive;
      function Intern (Input : Description) return Positive is
         Desc : Description := Input;
      begin
         if Desc.Shape.Kind = Aggregate_Field_Shape
           and then Desc.Shape.Nominal /= No_Nominal_Type
         then
            Desc := (Shape => (Kind => Aggregate_Field_Shape,
                              Nominal => Desc.Shape.Nominal, others => <>),
                     others => <>);
            if not Is_Union (Desc.Shape.Nominal) then
               declare
                  Decl : constant Declaration_Id :=
                    Template_Of (Of_Unit, Desc.Shape.Nominal);
                  Tree : constant access constant Landin.Syntax.Tree :=
                    Landin.Syntax.Forest.Tree_Of
                      (Info.Trees.all,
                       Landin.Resolution.Source_Of (Meanings, Decl));
                  Node : constant Landin.Syntax.Node_Id :=
                    Landin.Resolution.Node_Of (Meanings, Decl);
               begin
                  if Landin.Syntax.Kind (Tree.all, Node)
                    = Landin.Syntax.Type_Declaration
                  then
                     Desc.Source := Landin.Syntax.Source_Of (Tree.all);
                     Desc.Node := Landin.Syntax.Declared_Type (Tree.all, Node);
                  end if;
               end;
            end if;
         elsif Desc.Shape.Kind = Scalar_Field_Shape then
            Desc.Source := Landin.Source.No_Source;
            Desc.Node := Landin.Syntax.No_Node;
         end if;
         for Index in 1 .. Natural (Types.Length) loop
            if Types (Index) = Desc then
               return Index;
            end if;
         end loop;
         Types.Append (Desc);
         return Natural (Types.Length);
      end Intern;

      function Shape_Type
        (Shape : Field_Shape;
         Source : Landin.Source.Source_Id := Landin.Source.No_Source;
         Node : Landin.Syntax.Node_Id := Landin.Syntax.No_Node)
         return Positive is
        (Intern ((Shape => Shape, Source => Source, Node => Node,
                  others => <>)));

      procedure Coordinates (Site : Landin.Provenance.Origin);
      procedure Coordinates (Site : Landin.Provenance.Origin) is
         Pos : constant Landin.Source.Position := Landin.Source.Position_Of
           (Landin.Debugging.Source (Info, Site.Source), Site.Where.First);
      begin
         U (Natural (Site.Source));
         U (Natural (Pos.Line));
         U (Natural (Pos.Column));
      end Coordinates;

      procedure Member
        (Name : String; Typ : Positive; Offset : Landin.Targets.Byte_Count);
      procedure Member
        (Name : String; Typ : Positive; Offset : Landin.Targets.Byte_Count)
      is
      begin
         U (7);
         Str (Name);
         Ref (T (Typ));
         Put (HT & ".uleb128 " & Landin.Targets.Byte_Count'Image (Offset));
      end Member;

      --  [0570]: a slice is its base address and its length, in that order,
      --  named by the element it reaches where the element has a name.
      procedure Slice_Type (Element : Pointee_Id);
      procedure Slice_Type (Element : Pointee_Id) is
         Width : constant Landin.Targets.Byte_Count :=
           Landin.Targets.Byte_Count
             (Landin.Targets.Bytes (Landin.Targets.Pointer_Size (Facts)));
         Reached : constant Field_Shape := Pointee_Shape (Of_Unit, Element);
         Name : constant String :=
           (if Reached.Kind = Scalar_Field_Shape
              and then Reached.Pointee = No_Pointee
              and then Reached.Signature = No_Signature
              and then Reached.Atoms = No_Atom_Set
            then "[]" & Landin.Types.Spelling (Reached.Element)
            elsif Reached.Kind = Aggregate_Field_Shape
              and then Reached.Nominal /= No_Nominal_Type
            then "[]" & Nominal_Name (Reached.Nominal)
            else "slice");
      begin
         U (6);
         Str (Name);
         Put (HT & ".uleb128 " & Landin.Targets.Byte_Count'Image
           (2 * Width));
         Member ("ptr", Shape_Type
           ((Element => Landin.Types.Usize, Pointee => Element,
             others => <>)), 0);
         Member ("len", Shape_Type
           ((Element => Landin.Types.Usize, others => <>)), Width);
         U (0);
      end Slice_Type;

      procedure Emit_Type (Index : Positive);
      procedure Emit_Type (Index : Positive) is
         Desc : constant Description := Types (Index);
         Shape : constant Field_Shape := Desc.Shape;
         Size : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment;
         Tree : access constant Landin.Syntax.Tree;

         function Child_Node (Position : Positive)
            return Landin.Syntax.Node_Id;
         function Child_Node (Position : Positive)
            return Landin.Syntax.Node_Id
         is
         begin
            if Tree = null or else Desc.Node = Landin.Syntax.No_Node
              or else Landin.Syntax.Kind (Tree.all, Desc.Node)
                /= Landin.Syntax.Struct_Body
              or else Position > Landin.Syntax.Field_Count
                (Tree.all, Desc.Node)
            then
               return Landin.Syntax.No_Node;
            end if;
            return Landin.Syntax.Nth_Field (Tree.all, Desc.Node, Position);
         end Child_Node;

         function Node_Name
           (Node : Landin.Syntax.Node_Id; Fallback : String) return String;
         function Node_Name
           (Node : Landin.Syntax.Node_Id; Fallback : String) return String
         is
         begin
            if Tree = null or else Node = Landin.Syntax.No_Node
              or else not Landin.Syntax.Has_Name
                (Landin.Syntax.Kind (Tree.all, Node))
            then
               return Fallback;
            end if;
            return Landin.Source.Names.Spelling
              (Names, Landin.Syntax.Name (Tree.all, Node));
         end Node_Name;
      begin
         if Desc.Source /= Landin.Source.No_Source then
            Tree := Landin.Syntax.Forest.Tree_Of
              (Info.Trees.all, Desc.Source);
         end if;
         Put (T (Index) & ":");
         if Shape.Kind = Array_Field_Shape
           and then Shape.Slice_Element /= No_Pointee
         then
            Slice_Type (Shape.Slice_Element);
            return;
         elsif Shape.Kind = Aggregate_Field_Shape
           and then Shape.Nominal /= No_Nominal_Type
           and then not Has_Nominal_Shape (Of_Unit, Shape.Nominal)
         then
            --  DWARF4 2.13.1: an opaque pointee is a declaration, with no
            --  invented byte size or member layout.
            U (12);
            Str (Nominal_Name (Shape.Nominal));
            Put (HT & ".byte 1");
            return;
         elsif Desc.Item /= No_Item then
            Size := Slot_Layout (Of_Unit, Desc.Item, Desc.Slot, Facts).Size;
         elsif Shape.Kind /= Array_Field_Shape then
            --  An array DIE carries its element type and count. Its total
            --  byte extent need not be known for a pointer-to-array type.
            Field_Extent (Of_Unit, Shape, Facts, Size, Alignment);
         end if;
         if Shape.Kind = Aggregate_Field_Shape
           and then Layout_Of (Of_Unit, Shape) = Landin.Layouts.Packed
         then
            --  A raw image is not a set of byte-addressable fields.
            --  Expose its complete carrier, including unnamed encodings,
            --  without fabricating ordinary-array strides for bit arrays.
            U (6);
            Str (Nominal_Name (Shape.Nominal));
            U (Natural (Size));
            Member ("raw", Shape_Type
              ((Element => (case Size is
                   when 1 => Landin.Types.U8,
                   when 2 => Landin.Types.U16,
                   when 4 => Landin.Types.U32,
                   when others => Landin.Types.U64), others => <>)), 0);
            U (0);
            return;
         end if;
         case Shape.Kind is
            when Scalar_Field_Shape =>
               if Shape.Pointee /= No_Pointee then
                  U (5);
                  U (Natural (Size));
                  Ref (T (Shape_Type (Pointee_Shape
                    (Of_Unit, Shape.Pointee))));
               elsif Shape.Atoms /= No_Atom_Set then
                  --  D423: an atom set is an enumeration of its atoms,
                  --  each with the code this program gives it, so a
                  --  debugger prints a value by its atom's name.  The set
                  --  has no name of its own in the IR, so neither has the
                  --  type; its carrier is the type it refers to.
                  U (23);
                  U (Natural (Size));
                  Ref (T (Shape_Type ((Element => Shape.Element,
                                       others => <>))));
                  for Index in 1 .. Atom_Count (Of_Unit, Shape.Atoms) loop
                     U (24);
                     Str (Decl_Name (Nth_Atom (Of_Unit, Shape.Atoms, Index)));
                     U (Atom_Code
                       (Codes, Nth_Atom (Of_Unit, Shape.Atoms, Index)));
                  end loop;
                  U (0);
               else
                  U (4);
                  Str (Landin.Types.Spelling (Shape.Element));
                  U (Natural (Size));
                  U (if Shape.Element = Landin.Types.Bool then 2
                     elsif Shape.Element in Landin.Types.Float_Name then 4
                     elsif Shape.Element in Landin.Types.I8 .. Landin.Types.I64
                       or else Shape.Element = Landin.Types.Isize then 5
                     else 7);
               end if;
            when Array_Field_Shape =>
               U (8);
               Ref (T (Shape_Type (Array_Element_Shape (Of_Unit, Shape))));
               U (9);
               Put (HT & ".uleb128 " & Element_Total'Image (Shape.Length));
               U (0);
            when Aggregate_Field_Shape =>
               declare
                  Count : constant Natural :=
                    (if Desc.Item /= No_Item then Slot_Field_Count
                       (Of_Unit, Desc.Item, Desc.Slot)
                     else Aggregate_Field_Count (Of_Unit, Shape));
                  Fields : Field_Shape_Array (1 .. Count);
               begin
                  for Field in Fields'Range loop
                     Fields (Field) :=
                       (if Desc.Item /= No_Item then Nth_Slot_Field_Shape
                          (Of_Unit, Desc.Item, Desc.Slot, Field)
                        else Nth_Aggregate_Field (Of_Unit, Shape, Field));
                  end loop;
                  U (if Count = 0 then 13 else 6);
                  Str (if Shape.Nominal /= No_Nominal_Type then
                         Nominal_Name (Shape.Nominal)
                       else "aggregate");
                  Put (HT & ".uleb128 " & Landin.Targets.Byte_Count'Image
                    (Size));
                  declare
                     Placed : constant Landin.Targets.Layouts.Plan :=
                       (if Desc.Item /= No_Item then Slot_Layout
                          (Of_Unit, Desc.Item, Desc.Slot, Facts)
                        else Fields_Layout
                          (Of_Unit, Fields, Layout_Of (Of_Unit, Shape),
                           Facts));
                  begin
                     for Field in Fields'Range loop
                        declare
                           Node : constant Landin.Syntax.Node_Id :=
                             Child_Node (Field);
                           Name : constant Landin.Source.Names.Name_Id :=
                             (if Desc.Item = No_Item then
                                Landin.Source.Names.No_Name
                              else Landin.Debugging.Result_Name
                                (Info, Declares
                                   (Of_Unit, Desc.Item, Desc.Slot), Field));
                        begin
                           Member
                             ((if Is_Union (Shape.Nominal)
                               then (if Field = 1 then "atom" else "ptr")
                               else Node_Name (Node,
                                 (if Name = Landin.Source.Names.No_Name then
                                    "field_" & N (Field)
                                  else Landin.Source.Names.Spelling
                                    (Names, Name)))),
                             Shape_Type (Fields (Field), Desc.Source, Node),
                             Placed.Offsets (Field));
                        end;
                     end loop;
                  end;
                  if Count > 0 then
                     U (0);
                  end if;
               end;
            when Variant_Field_Shape =>
               --  A truthful C-like tagged overlay, not a claim that GDB
               --  implements Landin's match syntax.  tag is zero-based;
               --  each named case exposes its payload at the actual offsets.
               U (6);
               Str (Node_Name (Desc.Node, "variant"));
               Put (HT & ".uleb128 " & Landin.Targets.Byte_Count'Image (Size));
               Member ("tag", Shape_Type
                 ((Element => Shape.Element, others => <>)), 0);
               for Which in 1 .. Shape.Cases loop
                  declare
                     Case_Node : constant Landin.Syntax.Node_Id :=
                       (if Tree /= null
                          and then Desc.Node /= Landin.Syntax.No_Node
                          and then Landin.Syntax.Kind (Tree.all, Desc.Node)
                            = Landin.Syntax.Variant_Part
                        then Landin.Syntax.Nth_Case
                          (Tree.all, Desc.Node, Which)
                        else Landin.Syntax.No_Node);
                     Case_Label : constant String :=
                       T (Index) & "_case_" & N (Which);
                  begin
                     U (7);
                     Str (Node_Name (Case_Node, "case_" & N (Which - 1)));
                     Ref (Case_Label);
                     U (0);
                  end;
               end loop;
               U (0);
               for Which in 1 .. Shape.Cases loop
                  declare
                     Case_Node : constant Landin.Syntax.Node_Id :=
                       (if Tree /= null
                          and then Desc.Node /= Landin.Syntax.No_Node
                          and then Landin.Syntax.Kind (Tree.all, Desc.Node)
                            = Landin.Syntax.Variant_Part
                        then Landin.Syntax.Nth_Case
                          (Tree.all, Desc.Node, Which)
                        else Landin.Syntax.No_Node);
                  begin
                     Put (T (Index) & "_case_" & N (Which) & ":");
                     U (if Variant_Case_Field_Count
                       (Of_Unit, Shape, Which) = 0 then 13 else 6);
                     Str (Node_Name (Case_Node, "case_" & N (Which - 1)));
                     Put (HT & ".uleb128 "
                       & Landin.Targets.Byte_Count'Image (Size));
                     for Field in 1 .. Variant_Case_Field_Count
                       (Of_Unit, Shape, Which)
                     loop
                        declare
                           Node : constant Landin.Syntax.Node_Id :=
                             (if Case_Node /= Landin.Syntax.No_Node then
                                Landin.Syntax.Nth_Payload_Field
                                  (Tree.all, Case_Node, Field)
                              else Landin.Syntax.No_Node);
                        begin
                           Member (Node_Name (Node, "field_" & N (Field)),
                             Shape_Type (Nth_Variant_Case_Field
                               (Of_Unit, Shape, Which, Field),
                               Desc.Source, Node),
                             Variant_Payload_Field_Offset
                               (Of_Unit, Shape, Which, Field, Facts,
                                Type_Layouts));
                        end;
                     end loop;
                     if Variant_Case_Field_Count
                       (Of_Unit, Shape, Which) > 0
                     then
                        U (0);
                     end if;
                  end;
               end loop;
         end case;
      end Emit_Type;

      --  The scope a routine's own parameters and locals hang from: the
      --  signature scope above its first block.
      function Signature_Root (Item : Item_Id) return Scope_Id;
      function Signature_Root (Item : Item_Id) return Scope_Id is
         Root : Scope_Id := Scope_Of (Of_Unit, Item, First_Block);
      begin
         while Root /= Landin.Resolution.No_Scope
           and then Landin.Resolution.Sort_Of (Meanings, Root)
             /= Landin.Resolution.Signature
         loop
            Root := Landin.Resolution.Enclosing (Meanings, Root);
         end loop;
         return Root;
      end Signature_Root;

      function Routine_Name (Item : Item_Id) return String is
        (if (if Generic_Template_Of (Of_Unit, Item) /= No_Declaration
             then Generic_Template_Of (Of_Unit, Item)
             else Declares (Of_Unit, Item)) = No_Declaration
         then Symbol (Item)
         else Decl_Name
           (if Generic_Template_Of (Of_Unit, Item) /= No_Declaration
            then Generic_Template_Of (Of_Unit, Item)
            else Declares (Of_Unit, Item)));

      --  D339: a routine an inlined copy names is described once more,
      --  abstractly (DWARF4 3.3.8.1): its name, its parameters, locals and
      --  lexical blocks with their names and types and no address.  Every
      --  copy is a DW_TAG_inlined_subroutine whose entries refer to these
      --  for what they are and say only where they are.  The routine's own
      --  out-of-line description is the one it had.
      function Abstract_Label
        (Callee : Item_Id; Kind : String := ""; Index : Natural := 0)
         return String is
        (Prefix & "debug_abstract_" & N (Natural (Callee))
         & (if Kind = "" then "" else "_" & Kind & "_" & N (Index)));

      Abstract_Wanted : array (1 .. Item_Count (Of_Unit)) of Boolean :=
        [others => False];

      function Has_Inlined_Copies return Boolean is
        (for some Index in 1 .. Item_Count (Of_Unit) =>
           Kind_Of (Of_Unit, Item_Id (Index)) = Landin.IR.Routine
           and then Inline_Site_Count (Of_Unit, Item_Id (Index)) > 0);

      Inlined_Copies : constant Boolean := Has_Inlined_Copies;

      --  A slot's presented type.
      function Slot_Type (Item : Item_Id; Slot : Slot_Id) return Positive;
      function Slot_Type (Item : Item_Id; Slot : Slot_Id) return Positive is
         Shape : Field_Shape;
      begin
         if Is_Address (Of_Unit, Item, Slot) then
            Shape := Address_Shape (Of_Unit, Item, Slot);
         elsif Is_Array (Of_Unit, Item, Slot) then
            Shape := Whole_Slot_Array_Shape (Of_Unit, Item, Slot);
         elsif Is_Aggregate (Of_Unit, Item, Slot) then
            Shape := (Kind => Aggregate_Field_Shape,
                      Nominal => Nominal_Of (Of_Unit, Item, Slot),
                      others => <>);
         else
            Shape := (Element => Type_Of (Of_Unit, Item, Slot),
                      Pointee => Pointee_Of (Of_Unit, Item, Slot),
                      Atoms => Atom_Set_Of (Of_Unit, Item, Slot),
                      others => <>);
         end if;
         return (if Shape.Kind = Aggregate_Field_Shape
                   and then Shape.Nominal = No_Nominal_Type
                   and then not Is_Address (Of_Unit, Item, Slot)
                 then Intern ((Shape => Shape, Item => Item,
                              Slot => Slot, others => <>))
                 else Shape_Type (Shape));
      end Slot_Type;

      --  What a source alias presents, as Alias_Variables reaches it.
      function Alias_Shape
        (Item : Item_Id; Index : Positive) return Field_Shape;
      function Alias_Shape
        (Item : Item_Id; Index : Positive) return Field_Shape
      is
         Alias : constant Source_Alias :=
           Nth_Source_Alias (Of_Unit, Item, Index);
         Shape : Field_Shape;
      begin
         case Alias.Place.Kind is
            when Module_Datum =>
               if Result_Of (Of_Unit, Alias.Place.Datum)
                 = Landin.Types.Fixed_Array
               then
                  Shape := Whole_Array_Shape (Of_Unit, Alias.Place.Datum);
                  if Alias.Field > 0 then
                     Shape := Array_Element_Shape (Of_Unit, Shape);
                  end if;
               else
                  Shape := Nth_Field_Shape
                    (Of_Unit, Alias.Place.Datum, Alias.Field);
               end if;
            when Frame_Slot =>
               if Alias.Field > 0 then
                  Shape := (if Is_Array (Of_Unit, Item, Alias.Place.Slot)
                            then Slot_Array_Element_Shape
                              (Of_Unit, Item, Alias.Place.Slot)
                            else Nth_Slot_Field_Shape
                              (Of_Unit, Item, Alias.Place.Slot,
                               Alias.Field));
               elsif Is_Aggregate (Of_Unit, Item, Alias.Place.Slot) then
                  Shape := (Kind => Aggregate_Field_Shape,
                            Nominal => Nominal_Of
                              (Of_Unit, Item, Alias.Place.Slot),
                            others => <>);
               else
                  Shape := Whole_Slot_Array_Shape
                    (Of_Unit, Item, Alias.Place.Slot);
               end if;
            when Runtime_Address =>
               Shape := Address_Shape (Of_Unit, Item, Alias.Place.Address);
               if Alias.Field > 0 then
                  Shape := Shape_At
                    (Of_Unit, Shape,
                     [1 => (Part_Position (Alias.Field), 0)]);
               end if;
         end case;
         return Shape_At
           (Of_Unit, Shape, Source_Alias_Path (Of_Unit, Item, Index));
      end Alias_Shape;

      function Is_Parameter (Item : Item_Id; Slot : Slot_Id) return Boolean
        is (for some Index in 1 .. Parameter_Count (Of_Unit, Item) =>
              Nth_Parameter (Of_Unit, Item, Index) = Slot);

      package Index_Vectors is new Ada.Containers.Vectors
        (Positive, Positive);
      type Scope_Group is record
         Scope : Scope_Id;
         Slots, Aliases, Inlines, Children : Index_Vectors.Vector;
      end record;
      package Scope_Vectors is new Ada.Containers.Vectors
        (Positive, Scope_Group);
      package Scope_Maps is new Ada.Containers.Ordered_Maps
        (Scope_Id, Positive);

      --  The lexical scopes below Root that hold a declared slot or alias
      --  of Item belonging to Site (zero: Item's own), and, for Item's
      --  own, the scopes its inlined copies were called from.  Group 1 is
      --  Root.
      procedure Group_Scopes
        (Item : Item_Id; Site : Natural; Root : Scope_Id;
         Groups : in out Scope_Vectors.Vector;
         With_Copies : Boolean);
      procedure Group_Scopes
        (Item : Item_Id; Site : Natural; Root : Scope_Id;
         Groups : in out Scope_Vectors.Vector;
         With_Copies : Boolean)
      is
         Group_Indices : Scope_Maps.Map;

         procedure Add_Scope_Path (From : Scope_Id);
         procedure Add_Scope_Path (From : Scope_Id) is
            Scope : Scope_Id := From;
         begin
            while Scope /= Root
              and then Scope /= Landin.Resolution.No_Scope
            loop
               exit when Group_Indices.Contains (Scope);
               Groups.Append (Scope_Group'(Scope => Scope, others => <>));
               Group_Indices.Insert (Scope, Groups.Last_Index);
               Scope := Landin.Resolution.Enclosing (Meanings, Scope);
            end loop;
         end Add_Scope_Path;
      begin
         Groups.Append (Scope_Group'(Scope => Root, others => <>));
         Group_Indices.Insert (Root, 1);
         for Index in 1 .. Slot_Count (Of_Unit, Item) loop
            declare
               Binding : constant Declaration_Id :=
                 Declares (Of_Unit, Item, Slot_Id (Index));
            begin
               if Binding /= No_Declaration
                 and then Inlined_At (Of_Unit, Item, Slot_Id (Index)) = Site
               then
                  declare
                     Scope : constant Scope_Id :=
                       Landin.Resolution.Scope_Of (Meanings, Binding);
                  begin
                     Add_Scope_Path (Scope);
                     if Group_Indices.Contains (Scope) then
                        Groups.Reference
                          (Group_Indices.Element (Scope)).Slots.Append
                            (Index);
                     end if;
                  end;
               end if;
            end;
         end loop;
         for Index in 1 .. Source_Alias_Count (Of_Unit, Item) loop
            if Alias_Inlined_At (Of_Unit, Item, Index) = Site then
               declare
                  Scope : constant Scope_Id := Landin.Resolution.Scope_Of
                    (Meanings, Nth_Source_Alias
                       (Of_Unit, Item, Index).Binding);
               begin
                  Add_Scope_Path (Scope);
                  if Group_Indices.Contains (Scope) then
                     Groups.Reference
                       (Group_Indices.Element (Scope)).Aliases.Append (Index);
                  end if;
               end;
            end if;
         end loop;
         if With_Copies then
            for Copy in 1 .. Inline_Site_Count (Of_Unit, Item) loop
               declare
                  Scope : constant Scope_Id :=
                    Nth_Inline_Site (Of_Unit, Item, Copy).Scope;
               begin
                  Add_Scope_Path (Scope);
                  Groups.Reference
                    ((if Group_Indices.Contains (Scope)
                      then Group_Indices.Element (Scope) else 1)).Inlines
                    .Append (Copy);
               end;
            end loop;
         end if;
         for Index in 2 .. Natural (Groups.Length) loop
            declare
               Parent : constant Scope_Id := Landin.Resolution.Enclosing
                 (Meanings, Groups.Element (Index).Scope);
            begin
               if Group_Indices.Contains (Parent) then
                  Groups.Reference
                    (Group_Indices.Element (Parent)).Children.Append
                      (Index);
               end if;
            end;
         end loop;
      end Group_Scopes;

      procedure Routine
        (Item : Item_Id; Plan : Placement; Frame_Plan : Frame);
      procedure Routine
        (Item : Item_Id; Plan : Placement; Frame_Plan : Frame) is
         Availability : Debug_Locations.Analysis :=
           Debug_Locations.Prepare (Of_Unit, Item);
         Path_Layouts : Landin.IR.Shape_Measurement.Layout_Cache;
         function Has_Trap (Value : Value_Id) return Boolean is
           (Trapped /= null and then Trapped (Item, Value));
         Parameters : array (1 .. Slot_Count (Of_Unit, Item)) of Boolean :=
           [others => False];

         --  The routine a copy is of; Item itself for Site zero.
         function Origin_Item (Site : Natural) return Item_Id is
           (if Site = 0 then Item
            else Nth_Inline_Site (Of_Unit, Item, Site).Callee);

         --  The address ranges of Item's blocks belonging to Site whose
         --  scope is inside Scope (any scope when Scope is No_Scope), each
         --  with the traps laid out after the body for them.  A lexical
         --  block of Item's own holds the copies called inside it.
         procedure Range_List
           (Name : String; Site : Natural; Scope : Scope_Id);
         procedure Range_List
           (Name : String; Site : Natural; Scope : Scope_Id) is
         begin
            --  Entries below contain linked addresses, not offsets
            --  from a containing routine's low PC.  Select base zero
            --  explicitly. ELF has no single CU low PC; Darwin also
            --  supplies a relocatable base for dsymutil's rewrite.
            US.Append (Ranges, Name & ":" & LF
              & HT & ".quad -1,0" & LF);
            for B in 1 .. Block_Count (Of_Unit, Item) loop
               declare
                  Block : constant Block_Id := Block_Id (B);
                  Count : constant Natural := Length (Of_Unit, Item, Block);
               begin
                  if Count > 0
                    and then
                      (if Inlined_At (Of_Unit, Item, Block) = Site
                       then Scope = Landin.Resolution.No_Scope
                         or else Debug_Locations.Within
                           (Meanings, Scope_Of (Of_Unit, Item, Block), Scope)
                       else Site = 0
                         and then Scope /= Landin.Resolution.No_Scope
                         and then Debug_Locations.Within
                           (Meanings,
                            Nth_Inline_Site
                              (Of_Unit, Item,
                               Inlined_At (Of_Unit, Item, Block)).Scope,
                            Scope))
                  then
                     US.Append (Ranges, HT & ".quad "
                       & L ("value", Item, Natural (Nth_Value
                         (Of_Unit, Item, Block, 1))) & LF
                       & HT & ".quad " & L ("after", Item,
                         Natural (Nth_Value (Of_Unit, Item, Block, Count)))
                       & LF);
                     for P in 1 .. Count loop
                        declare
                           V : constant Natural := Natural
                             (Nth_Value (Of_Unit, Item, Block, P));
                        begin
                           if Has_Trap (Value_Id (V)) then
                              US.Append (Ranges, HT & ".quad "
                                & L ("trap", Item, V) & LF
                                & HT & ".quad " & L ("trapped", Item, V)
                                & LF);
                           end if;
                        end;
                     end loop;
                  end if;
               end;
            end loop;
            US.Append (Ranges, HT & ".quad 0,0" & LF);
         end Range_List;

         --  ELF startup objects may contribute to these sections before
         --  us. A section relocation carries the final linked offset;
         --  subtracting our own start would address another object.
         procedure Ranges_Attribute (Name : String);
         procedure Ranges_Attribute (Name : String) is
         begin
            Put (HT & ".long " & Name
              & (if Mach_O then "-" & Prefix & "debug_ranges" else ""));
         end Ranges_Attribute;

         --  Overwriter, when not No_Value, is a value Live leaves out
         --  whose first instruction still finds the location: the range
         --  ending before it extends over that instruction's first
         --  address, the only place a debugger can stop before it runs.
         procedure Location_List
           (Loc : String; Expr : US.Unbounded_String;
            Live : Debug_Locations.Flags.Vector;
            Overwriter : Value_Id := No_Value);
         procedure Location_List
           (Loc : String; Expr : US.Unbounded_String;
            Live : Debug_Locations.Flags.Vector;
            Overwriter : Value_Id := No_Value)
         is
            First, Last : Value_Id := No_Value;
            procedure Flush (Entered : Boolean := False);
            procedure Flush (Entered : Boolean := False) is
               E : constant String := Loc & "_expr_" & N (Natural (First));
            begin
               if First /= No_Value then
                  US.Append (Locations,
                    HT & ".quad " & L ("value", Item, Natural (First)) & LF
                    & HT & ".quad "
                    & (if Entered
                       then L ("value", Item, Natural (Last)) & "+1"
                       else L
                         ((if Op_Of (Of_Unit, Item, Last) in Leave | Fail
                           then "epilogue" else "after"),
                          Item, Natural (Last)))
                    & LF
                    & HT & ".short " & E & "_end-" & E & LF
                    & E & ":" & LF & US.To_String (Expr)
                    & E & "_end:" & LF);
                  First := No_Value;
               end if;
            end Flush;
         begin
            US.Append (Locations, Loc & ":" & LF & HT & ".quad -1,0" & LF);
            if US.Length (Expr) > 0 then
               for B in 1 .. Block_Count (Of_Unit, Item) loop
                  for P in 1 .. Length (Of_Unit, Item, Block_Id (B)) loop
                     declare
                        Value : constant Value_Id := Nth_Value
                          (Of_Unit, Item, Block_Id (B), P);
                     begin
                        if Live (Positive (Value)) then
                           if First = No_Value then
                              First := Value;
                           end if;
                           Last := Value;
                           --  A following laid-out block must not join a
                           --  range across this return's register restores.
                           if Op_Of (Of_Unit, Item, Value) in Leave | Fail then
                              Flush;
                           end if;
                        elsif Value = Overwriter then
                           if First = No_Value then
                              First := Value;
                           end if;
                           Last := Value;
                           Flush (Entered => True);
                        else
                           Flush;
                        end if;
                     end;
                  end loop;
               end loop;
               Flush;
               --  A trap after the body sees what its operation saw.
               for V in 1 .. Value_Count (Of_Unit, Item) loop
                  if Live (V) and then Has_Trap (Value_Id (V)) then
                     declare
                        E : constant String := Loc & "_trap_" & N (V);
                     begin
                        US.Append (Locations,
                          HT & ".quad " & L ("trap", Item, V) & LF
                          & HT & ".quad " & L ("trapped", Item, V) & LF
                          & HT & ".short " & E & "_end-" & E & LF
                          & E & ":" & LF & US.To_String (Expr)
                          & E & "_end:" & LF);
                     end;
                  end if;
               end loop;
            end if;
            US.Append (Locations, HT & ".quad 0,0" & LF);
         end Location_List;

         procedure Alias_Variables
           (Indices : Index_Vectors.Vector; Site : Natural);
         procedure Alias_Variables
           (Indices : Index_Vectors.Vector; Site : Natural) is
         begin
            for Index of Indices loop
               declare
                  Alias : constant Source_Alias :=
                    Nth_Source_Alias (Of_Unit, Item, Index);
                  Path : constant Path_Step_Array :=
                    Source_Alias_Path (Of_Unit, Item, Index);
                  Loc : constant String := L ("alias_loc", Item, Index);
                  Shape : Field_Shape;
                  Offset : Landin.Targets.Byte_Count := 0;
                  Expr : US.Unbounded_String;

                  procedure Frame_Address (Slot : Slot_Id; Indirect : Boolean);
                  procedure Frame_Address (Slot : Slot_Id; Indirect : Boolean)
                  is
                  begin
                     Expr := US.To_Unbounded_String
                       (Slot_Expression (Plan, Frame_Plan, Slot,
                                         Indirect, True));
                  end Frame_Address;
               begin
                  case Alias.Place.Kind is
                     when Module_Datum =>
                        Expr := US.To_Unbounded_String
                          (Datum_Expression (Alias.Place.Datum));
                        if Result_Of (Of_Unit, Alias.Place.Datum)
                          = Landin.Types.Fixed_Array
                        then
                           Shape := Whole_Array_Shape
                             (Of_Unit, Alias.Place.Datum);
                           if Alias.Field > 0 then
                              Offset := Landin.Backend.Path_Offset
                                (Of_Unit, Shape,
                                 [1 => (Part_Position (Alias.Field), 0)],
                                 Facts, Path_Layouts);
                              Shape := Array_Element_Shape
                                (Of_Unit, Shape);
                           end if;
                        elsif Alias.Field = 0 then
                           raise Landin.Compiler_Defect with
                             "a whole datum alias requires array storage";
                        else
                           Shape := Nth_Field_Shape
                             (Of_Unit, Alias.Place.Datum, Alias.Field);
                           Offset := Datum_Layout
                             (Of_Unit, Alias.Place.Datum, Facts).Offsets
                               (Alias.Field);
                        end if;
                     when Frame_Slot =>
                        Frame_Address (Alias.Place.Slot, False);
                        if Alias.Field > 0 then
                           Shape := (if Is_Array
                             (Of_Unit, Item, Alias.Place.Slot)
                             then Slot_Array_Element_Shape
                               (Of_Unit, Item, Alias.Place.Slot)
                             else Nth_Slot_Field_Shape
                               (Of_Unit, Item, Alias.Place.Slot,
                                Alias.Field));
                           if Has_Slot_Home
                             (Frame_Plan, Alias.Place.Slot)
                           then
                              Offset := Slot_Offset
                                (Frame_Plan, Alias.Place.Slot)
                                - Field_Offset
                                  (Of_Unit, Item, Frame_Plan,
                                   Alias.Place.Slot,
                                   Part_Position (Alias.Field), Facts);
                           end if;
                        elsif Is_Array (Of_Unit, Item, Alias.Place.Slot)
                        then
                           Shape := Whole_Slot_Array_Shape
                             (Of_Unit, Item, Alias.Place.Slot);
                        elsif Alias_Inlined_Parameter (Of_Unit, Item, Index)
                          /= No_Slot
                          and then Is_Aggregate
                            (Of_Unit, Item, Alias.Place.Slot)
                        then
                           --  D339: a copied parameter read in place.
                           Shape := (Kind => Aggregate_Field_Shape,
                                     Nominal => Nominal_Of
                                       (Of_Unit, Item, Alias.Place.Slot),
                                     others => <>);
                        else
                           raise Landin.Compiler_Defect with
                             "a whole slot alias requires array storage";
                        end if;
                     when Runtime_Address =>
                        Frame_Address (Alias.Place.Address, True);
                        Shape := Address_Shape
                          (Of_Unit, Item, Alias.Place.Address);
                        if Alias.Field > 0 then
                           declare
                              Base : constant Path_Step_Array :=
                                [1 => (Part_Position (Alias.Field), 0)];
                           begin
                              Offset := Landin.Backend.Path_Offset
                                (Of_Unit, Shape, Base, Facts, Path_Layouts);
                              Shape := Shape_At (Of_Unit, Shape, Base);
                           end;
                        end if;
                  end case;
                  Offset := Offset + Landin.Backend.Path_Offset
                    (Of_Unit, Shape, Path, Facts, Path_Layouts);
                  Shape := Shape_At (Of_Unit, Shape, Path);
                  if Offset > 0 and then US.Length (Expr) > 0 then
                     US.Append (Expr, HT & ".byte 0x23" & LF
                       & HT & ".uleb128 "
                       & Landin.Targets.Byte_Count'Image (Offset) & LF);
                  end if;
                  if Site = 0 then
                     U (10);
                     Str (Decl_Name (Alias.Binding));
                     Ref (T (Shape_Type (Shape)));
                     Coordinates (Alias.Site);
                  elsif Alias_Inlined_Parameter (Of_Unit, Item, Index)
                    /= No_Slot
                  then
                     U (20);
                     Ref (Abstract_Label
                       (Origin_Item (Site), "slot",
                        Natural (Alias_Inlined_Parameter
                          (Of_Unit, Item, Index))));
                  else
                     U (21);
                     Ref (Abstract_Label
                       (Origin_Item (Site), "alias",
                        Alias_Inlined_Origin (Of_Unit, Item, Index)));
                  end if;
                  Put (HT & ".long " & Loc
                    & (if Mach_O then "-" & Prefix & "debug_loc" else ""));
                  Location_List
                    (Loc, Expr, Debug_Locations.Available_Alias
                       (Availability, Of_Unit, Meanings, Info, Item, Index));
               end;
            end loop;
         end Alias_Variables;

         --  A variable scalar replacement split lives in its pieces: each
         --  piece's location and DW_OP_piece with its size, in address
         --  order, any padding an empty piece.  It is available where every
         --  piece is, and has no location if one piece has none.
         procedure Pieces (Slot : Slot_Id; Loc : String);
         procedure Pieces (Slot : Slot_Id; Loc : String) is
            Count : constant Positive :=
              Positive (Slot_Part_Count (Of_Unit, Item, Slot));
            First : constant Slot_Id := First_Piece (Of_Unit, Item, Slot);
            type Extents is array (1 .. Count) of Landin.Targets.Byte_Count;
            Offsets, Sizes : Extents;
            Placed : array (1 .. Count) of Boolean := [others => False];
            Total : Landin.Targets.Byte_Count := 0;
            Covered : Landin.Targets.Byte_Count := 0;
            Expr : US.Unbounded_String;
            Live : Debug_Locations.Flags.Vector;

            function Piece (Size : Landin.Targets.Byte_Count) return String
              is (HT & ".byte 0x93" & LF & HT & ".uleb128"
                  & Landin.Targets.Byte_Count'Image (Size) & LF);
         begin
            if Is_Array (Of_Unit, Item, Slot) then
               declare
                  Size : constant Landin.Targets.Byte_Count :=
                    Landin.Targets.Byte_Count (Landin.Targets.Bytes
                      (Size_Of (Slot_Array_Element (Of_Unit, Item, Slot),
                                Facts)));
               begin
                  for Part in 1 .. Count loop
                     Offsets (Part) :=
                       Landin.Targets.Byte_Count (Part - 1) * Size;
                     Sizes (Part) := Size;
                  end loop;
                  Total := Landin.Targets.Byte_Count (Count) * Size;
               end;
            else
               declare
                  Layout : constant Landin.Targets.Layouts.Plan :=
                    Slot_Layout (Of_Unit, Item, Slot, Facts);
               begin
                  for Part in 1 .. Count loop
                     Offsets (Part) := Layout.Offsets (Part);
                     Sizes (Part) := Landin.Targets.Byte_Count
                       (Landin.Targets.Bytes (Size_Of (Nth_Slot_Part
                          (Of_Unit, Item, Slot, Part_Position (Part)),
                           Facts)));
                  end loop;
                  Total := Layout.Size;
               end;
            end if;
            Live.Append (True, Ada.Containers.Count_Type
              (Value_Count (Of_Unit, Item)));
            for Step in 1 .. Count loop
               declare
                  Next : Natural := 0;
               begin
                  for Part in 1 .. Count loop
                     if not Placed (Part)
                       and then (Next = 0
                                 or else Offsets (Part) < Offsets (Next))
                     then
                        Next := Part;
                     end if;
                  end loop;
                  Placed (Next) := True;
                  declare
                     Held : constant Slot_Id := First + Slot_Id (Next - 1);
                     Where : constant String :=
                       Slot_Expression (Plan, Frame_Plan, Held, False, False);
                     Here : Debug_Locations.Flags.Vector :=
                       Debug_Locations.Available_Piece
                         (Availability, Of_Unit, Meanings, Info, Item,
                          Slot, Held);
                     --  An overwriter describes one piece, not the whole.
                     Overwriter : Value_Id := No_Value;
                  begin
                     if Where = "" then
                        Location_List (Loc, US.Null_Unbounded_String, Live);
                        return;
                     end if;
                     if Offsets (Next) > Covered then
                        US.Append (Expr, Piece (Offsets (Next) - Covered));
                     end if;
                     US.Append (Expr, Where & Piece (Sizes (Next)));
                     Covered := Offsets (Next) + Sizes (Next);
                     Narrow (Of_Unit, Item, Plan, Held, Here, Overwriter);
                     for Value in 1 .. Live.Last_Index loop
                        Live (Value) := Live (Value) and then Here (Value);
                     end loop;
                  end;
               end;
            end loop;
            if Total > Covered then
               US.Append (Expr, Piece (Total - Covered));
            end if;
            Location_List (Loc, Expr, Live);
         end Pieces;

         procedure Variables (Indices : Index_Vectors.Vector; Site : Natural);
         procedure Variables (Indices : Index_Vectors.Vector; Site : Natural)
         is
         begin
            for Index of Indices loop
               declare
                  Slot : constant Slot_Id := Slot_Id (Index);
                  Binding : constant Declaration_Id :=
                    Declares (Of_Unit, Item, Slot);
                  Parameter : constant Boolean := Parameters (Index);
                  Expr : US.Unbounded_String;
                  Loc : constant String := L ("loc", Item, Index);
               begin
                  if Site = 0 then
                     U (if Parameter then 3 else 10);
                     Str (Decl_Name (Binding));
                     Ref (T (Slot_Type (Item, Slot)));
                     Coordinates (Origin_Of (Of_Unit, Item, Slot));
                  else
                     U (if Is_Parameter
                          (Origin_Item (Site),
                           Inlined_Origin (Of_Unit, Item, Slot))
                        then 20 else 21);
                     Ref (Abstract_Label
                       (Origin_Item (Site), "slot",
                        Natural (Inlined_Origin (Of_Unit, Item, Slot))));
                  end if;
                  Put (HT & ".long " & Loc
                    & (if Mach_O then "-" & Prefix & "debug_loc" else ""));
                  if First_Piece (Of_Unit, Item, Slot) /= No_Slot then
                     Pieces (Slot, Loc);
                  else
                     Expr := US.To_Unbounded_String
                       (Slot_Expression (Plan, Frame_Plan, Slot,
                          Is_Address (Of_Unit, Item, Slot), False));
                     declare
                        Live : Debug_Locations.Flags.Vector :=
                          Debug_Locations.Available
                            (Availability, Of_Unit, Meanings, Info,
                             Item, Slot, Parameter);
                        Overwriter : Value_Id := No_Value;
                     begin
                        Narrow (Of_Unit, Item, Plan, Slot, Live, Overwriter);
                        Location_List (Loc, Expr, Live, Overwriter);
                     end;
                  end if;
               end;
            end loop;
         end Variables;

         procedure Inlined_Subroutine (Site : Positive);

         procedure Lexical_Scope
           (Groups : Scope_Vectors.Vector; Group_Index : Positive;
            Site : Natural; Is_Root : Boolean := False);
         procedure Lexical_Scope
           (Groups : Scope_Vectors.Vector; Group_Index : Positive;
            Site : Natural; Is_Root : Boolean := False)
         is
            Group : constant Scope_Group := Groups.Element (Group_Index);
            Name : constant String :=
              (if Site = 0 then L ("scope", Item, Natural (Group.Scope))
               else Prefix & "debug_iscope_" & N (Natural (Item)) & "_"
                 & N (Site) & "_" & N (Natural (Group.Scope)));
         begin
            if not Is_Root then
               if Site = 0 then
                  U (11);
               else
                  U (22);
                  Ref (Abstract_Label
                    (Origin_Item (Site), "scope", Natural (Group.Scope)));
               end if;
               Ranges_Attribute (Name);
               Range_List (Name, Site, Group.Scope);
            end if;
            Variables (Group.Slots, Site);
            Alias_Variables (Group.Aliases, Site);
            for Copy of Group.Inlines loop
               Inlined_Subroutine (Copy);
            end loop;
            for Child of Group.Children loop
               Lexical_Scope (Groups, Child, Site);
            end loop;
            if not Is_Root then
               U (0);
            end if;
         end Lexical_Scope;

         --  One inlined copy: where it is, what routine it is, where it
         --  was called from, and its own parameters, locals and blocks.
         procedure Inlined_Subroutine (Site : Positive) is
            Copy : constant Inline_Site :=
              Nth_Inline_Site (Of_Unit, Item, Site);
            Name : constant String :=
              Prefix & "debug_inline_" & N (Natural (Item)) & "_" & N (Site);
            Groups : Scope_Vectors.Vector;
         begin
            Abstract_Wanted (Positive (Copy.Callee)) := True;
            U (19);
            Ref (Abstract_Label (Copy.Callee));
            Ranges_Attribute (Name);
            Range_List (Name, Site, Landin.Resolution.No_Scope);
            Coordinates (Copy.Call);
            Group_Scopes
              (Item, Site, Signature_Root (Copy.Callee), Groups, False);
            Lexical_Scope (Groups, 1, Site, Is_Root => True);
            U (0);
         end Inlined_Subroutine;

         Groups : Scope_Vectors.Vector;
      begin
         U (2);
         Str (Routine_Name (Item));
         --  The source name is the debugger lookup name.  An assembler
         --  alias (notably a discarded .L generic-instance label) is not
         --  a source-language linkage name that GDB can demangle.
         Put (HT & ".quad " & L ("begin", Item));
         Put (HT & ".quad " & L ("end", Item));
         --  The backend frame register, not the CFA above that record.
         Put (HT & ".uleb128 1" & LF & HT & ".byte "
           & (if Frame_Register = 6 then "0x56"
              else N (16#50# + Frame_Register)));
         Coordinates (Origin_Of (Of_Unit, Item));
         for Index in 1 .. Parameter_Count (Of_Unit, Item) loop
            Parameters (Positive (Nth_Parameter (Of_Unit, Item, Index))) :=
              True;
         end loop;
         Group_Scopes (Item, 0, Signature_Root (Item), Groups, True);
         Lexical_Scope (Groups, 1, 0, Is_Root => True);
         U (0);
      end Routine;

      --  The abstract description of a routine an inlined copy names.
      procedure Abstract_Routine (Item : Item_Id);
      procedure Abstract_Routine (Item : Item_Id) is
         Groups : Scope_Vectors.Vector;

         procedure Abstract_Scope
           (Group_Index : Positive; Is_Root : Boolean := False);
         procedure Abstract_Scope
           (Group_Index : Positive; Is_Root : Boolean := False)
         is
            Group : constant Scope_Group := Groups.Element (Group_Index);
         begin
            if not Is_Root then
               Put (Abstract_Label (Item, "scope", Natural (Group.Scope))
                    & ":");
               U (18);
            end if;
            for Index of Group.Slots loop
               declare
                  Slot : constant Slot_Id := Slot_Id (Index);
               begin
                  Put (Abstract_Label (Item, "slot", Index) & ":");
                  U (if Is_Parameter (Item, Slot) then 16 else 17);
                  Str (Decl_Name (Declares (Of_Unit, Item, Slot)));
                  Ref (T (Slot_Type (Item, Slot)));
                  Coordinates (Origin_Of (Of_Unit, Item, Slot));
               end;
            end loop;
            for Index of Group.Aliases loop
               declare
                  Alias : constant Source_Alias :=
                    Nth_Source_Alias (Of_Unit, Item, Index);
               begin
                  Put (Abstract_Label (Item, "alias", Index) & ":");
                  U (17);
                  Str (Decl_Name (Alias.Binding));
                  Ref (T (Shape_Type (Alias_Shape (Item, Index))));
                  Coordinates (Alias.Site);
               end;
            end loop;
            for Child of Group.Children loop
               Abstract_Scope (Child);
            end loop;
            if not Is_Root then
               U (0);
            end if;
         end Abstract_Scope;
      begin
         Put (Abstract_Label (Item) & ":");
         U (15);
         Str (Routine_Name (Item));
         Coordinates (Origin_Of (Of_Unit, Item));
         --  DW_INL_inlined.
         Put (HT & ".byte 1");
         Group_Scopes (Item, 0, Signature_Root (Item), Groups, False);
         Abstract_Scope (1, Is_Root => True);
         U (0);
      end Abstract_Routine;

      --  A module datum lives at its symbol for the whole run, so it is a
      --  compilation-unit variable with one fixed address, not a location
      --  list.  Text and other anonymous datums have no source name.
      procedure Module_Datum (Item : Item_Id);
      procedure Module_Datum (Item : Item_Id) is
         Typ : Positive;
      begin
         if Result_Of (Of_Unit, Item) = Landin.Types.Fixed_Array then
            Typ := Shape_Type (Whole_Array_Shape (Of_Unit, Item));
         elsif Result_Of (Of_Unit, Item) = Landin.Types.Aggregate then
            if Nominal_Of (Of_Unit, Item) = No_Nominal_Type then
               return;
            end if;
            Typ := Shape_Type
              ((Kind => Aggregate_Field_Shape,
                Nominal => Nominal_Of (Of_Unit, Item), others => <>));
         elsif Result_Of (Of_Unit, Item) in Landin.Types.Scalar_Name then
            Typ := Shape_Type
              ((Element => Result_Of (Of_Unit, Item),
                Pointee => Pointee_Of (Of_Unit, Item),
                Atoms => Atom_Set_Of (Of_Unit, Item), others => <>));
         else
            return;
         end if;
         declare
            Expression : constant String := Datum_Expression (Item);
         begin
            if Expression = "" then
               return;
            end if;
            U (14);
            Str (Decl_Name (Declares (Of_Unit, Item)));
            Ref (T (Typ));
            Coordinates (Origin_Of (Of_Unit, Item));
            --  DW_OP_addr and an address, or DW_OP_const8u, an offset and
            --  DW_OP_form_tls_address.
            U (if Landin.Backend.In_Thread_Storage (Of_Unit, Facts, Item)
               then 10 else 9);
            US.Append (Result, Expression);
         end;
      end Module_Datum;

      procedure Abbreviation
        (Code, Tag : Natural; Children : Boolean; Attributes : String);
      procedure Abbreviation
        (Code, Tag : Natural; Children : Boolean; Attributes : String)
      is
         Fields : constant String :=
           (if Attributes = "" then "0,0" else Attributes & ",0,0");
         First : Positive := Fields'First;
      begin
         U (Code);
         U (Tag);
         Put (HT & ".byte " & (if Children then "1" else "0"));
         if Single_LEB_Operand then
            for Index in Fields'Range loop
               if Fields (Index) = ',' then
                  Put (HT & ".uleb128 " & Fields (First .. Index - 1));
                  First := Index + 1;
               end if;
            end loop;
            Put (HT & ".uleb128 " & Fields (First .. Fields'Last));
         else
            Put (HT & ".uleb128 " & Fields);
         end if;
      end Abbreviation;
   begin
      Put (Section ("abbrev", Mach_O));
      Put (Prefix & "debug_abbrev:");
      --  Attribute/form pairs from DWARF4. Strings are inline; all DIE
      --  references are CU-relative ref4, code addresses are target addr.
      Abbreviation (1, 16#11#, True,
        "0x25,0x08,0x13,0x05,0x03,0x08,0x1b,0x08,0x10,0x17"
        & (if Mach_O then ",0x11,0x01" else ""));
      Abbreviation (2, 16#2e#, True,
        "0x03,0x08,0x11,0x01,0x12,0x01,0x40,0x18,"
        & "0x3a,0x0f,0x3b,0x0f,0x39,0x0f");
      Abbreviation (3, 16#05#, False,
        "0x03,0x08,0x49,0x13,0x3a,0x0f,0x3b,0x0f,0x39,0x0f,0x02,0x17");
      Abbreviation (4, 16#24#, False, "0x03,0x08,0x0b,0x0f,0x3e,0x0f");
      Abbreviation (5, 16#0f#, False, "0x0b,0x0f,0x49,0x13");
      Abbreviation (6, 16#13#, True, "0x03,0x08,0x0b,0x0f");
      Abbreviation (7, 16#0d#, False, "0x03,0x08,0x49,0x13,0x38,0x0f");
      Abbreviation (8, 16#01#, True, "0x49,0x13");
      Abbreviation (9, 16#21#, False, "0x37,0x0f");
      Abbreviation (10, 16#34#, False,
        "0x03,0x08,0x49,0x13,0x3a,0x0f,0x3b,0x0f,0x39,0x0f,0x02,0x17");
      Abbreviation (11, 16#0b#, True, "0x55,0x17");
      --  structure_type: name/string and declaration/flag, no children.
      Abbreviation (12, 16#13#, False, "0x03,0x08,0x3c,0x0c");
      --  Empty represented structures have a size but no child DIEs.
      Abbreviation (13, 16#13#, False, "0x03,0x08,0x0b,0x0f");
      --  A module variable: one address expression, never a list.
      Abbreviation (14, 16#34#, False,
        "0x03,0x08,0x49,0x13,0x3a,0x0f,0x3b,0x0f,0x39,0x0f,0x02,0x18");
      --  D339's inlined copies, only where a unit has one, so a unit
      --  without keeps its bytes: the abstract routine with
      --  DW_AT_inline, its parameter, variable and lexical block with no
      --  location, and the copy with its abstract origin, ranges and
      --  call file, line and column, its parameter, variable and block.
      if Inlined_Copies then
         Abbreviation (15, 16#2e#, True,
           "0x03,0x08,0x3a,0x0f,0x3b,0x0f,0x39,0x0f,0x20,0x0b");
         Abbreviation (16, 16#05#, False,
           "0x03,0x08,0x49,0x13,0x3a,0x0f,0x3b,0x0f,0x39,0x0f");
         Abbreviation (17, 16#34#, False,
           "0x03,0x08,0x49,0x13,0x3a,0x0f,0x3b,0x0f,0x39,0x0f");
         Abbreviation (18, 16#0b#, True, "");
         Abbreviation (19, 16#1d#, True,
           "0x31,0x13,0x55,0x17,0x58,0x0f,0x59,0x0f,0x57,0x0f");
         Abbreviation (20, 16#05#, False, "0x31,0x13,0x02,0x17");
         Abbreviation (21, 16#34#, False, "0x31,0x13,0x02,0x17");
         Abbreviation (22, 16#0b#, True, "0x31,0x13,0x55,0x17");
      end if;
      --  D423's atom sets, only where a unit has one, as above: an
      --  enumeration with its size and carrier type, and each enumerator
      --  with its name and unsigned code.
      if Atom_Set_Count (Of_Unit) > 0 then
         Abbreviation (23, 16#04#, True, "0x0b,0x0f,0x49,0x13");
         Abbreviation (24, 16#28#, False, "0x03,0x08,0x1c,0x0f");
      end if;
      U (0);
      Put (Section ("info", Mach_O));
      Put (CU & ":");
      Put (HT & ".long " & CU & "_end-" & CU & "-4");
      Put (HT & ".short 4");
      Put (HT & ".long " & (if Mach_O then "0"
        else Prefix & "debug_abbrev"));
      Put (HT & ".byte 8");
      U (1);
      Str ("Landin refine");
      --  C's expression/display rules are a debugger presentation, not a
      --  language claim.  Landin expressions are not evaluated by GDB.
      Put (HT & ".short 0x0002");
      Str (Landin.Debugging.Recorded_Name (Info, 1));
      Str (Landin.Debugging.Directory (Info));
      Put (HT & ".long " & (if Mach_O then "0"
        else Prefix & "debug_line"));
      if Mach_O then
         Put (HT & ".quad " & Prefix & "debug_text");
      end if;
      for Index in 1 .. Item_Count (Of_Unit) loop
         declare
            Item : constant Item_Id := Item_Id (Index);
         begin
            if Kind_Of (Of_Unit, Item) = Landin.IR.Routine
              and then not Is_External (Of_Unit, Item)
            then
               if Cached_Plan = null then
                  declare
                     Plan : constant Placement :=
                       Make (Of_Unit, Item, Facts, Options);
                     Frame_Plan : constant Frame :=
                       Frame_For (Of_Unit, Item, Facts, Plan, Options);
                  begin
                     Routine (Item, Plan, Frame_Plan);
                  end;
               else
                  Routine
                    (Item, Cached_Plan (Item).all, Cached_Frame (Item).all);
               end if;
            elsif Kind_Of (Of_Unit, Item) = Landin.IR.Datum
              and then Declares (Of_Unit, Item) /= No_Declaration
            then
               Module_Datum (Item);
            end if;
         end;
      end loop;
      for Index in Abstract_Wanted'Range loop
         if Abstract_Wanted (Index) then
            Abstract_Routine (Item_Id (Index));
         end if;
      end loop;
      declare
         Index : Positive := 1;
      begin
         while Index <= Natural (Types.Length) loop
            Emit_Type (Index);
            Index := Index + 1;
         end loop;
      end;
      U (0);
      Put (CU & "_end:");
      Put (Section ("loc", Mach_O));
      Put (Prefix & "debug_loc:");
      US.Append (Result, Locations);
      Put (Section ("ranges", Mach_O));
      Put (Prefix & "debug_ranges:");
      US.Append (Result, Ranges);
      return US.To_String (Result);
   end Sections;

end Landin.Backend.Dwarf;
