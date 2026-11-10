--  Bindings from C headers, as `refine bindings` makes them (D820).
--
--  A binding is four files: `bindings.ldn`, the Landin declarations a
--  program imports; `adapters.c`, the C a header's records, globals,
--  nullable callbacks and incoming variadic entries need on the C side;
--  `exports.h`, which includes the headers and declares every adapter; and
--  `bindings.json`, what was bound, from which inputs, with the hashes of
--  the other three.  `bindings/README.md` describes the policy and every
--  form a header's declarations take.
--
--  What a header says is Clang's, never read here from its text: the
--  command runs the pinned Clang and hands this package what it printed,
--  its JSON AST of the headers, the preprocessed headers and the answers to
--  its probes, so the whole generator is a function of bytes and a test can
--  run it on literals.  Nothing here reads a file or runs a process.
--
--  A session is used in order: Load_Policy; Check_Triple; Check_Macros;
--  Strip_Markers;
--  Read_Ast; when Needs_Probe, Probe_Source and Read_Probe; Generate; and
--  then the four outputs.  The first fault ends it: Ok turns false, Fault
--  says why, and every later step does nothing.

with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Landin.Platform;
with Landin.Targets;

private with Ada.Containers.Indefinite_Ordered_Maps;
private with Ada.Containers.Indefinite_Ordered_Sets;
private with Ada.Containers.Vectors;
private with Ada.Finalization;
private with Landin.Json;

package Landin.Bindings is

   --  The ABIs a binding is made for, each one row of facts: the Clang
   --  triple, the compiler fact its bindings assert, the calling
   --  convention its metadata names, the data model, the sign of its plain
   --  char and the macros that identify it.  Another ABI is a row here and
   --  nowhere else.  Cortex-M is one refine target with two rows, AAPCS32's
   --  base procedure call standard and its VFP variant, which the policy's
   --  triple and calling convention choose between (D935).
   type Target is
     (Linux_X86_64, Darwin_Arm64, Linux_Arm64, Cortex_M_AAPCS,
      Cortex_M_AAPCS_VFP);

   function Triple (Of_Target : Target) return String;

   --  The refine target name each is, as `--target` spells it.
   function Target_Name (Of_Target : Target) return String;

   --  The compiler fact a generated binding asserts.
   function Fact (Of_Target : Target) return String;

   --  What a generated binding asserts of the float unit beside its fact,
   --  or "" where the fact alone selects the convention (D936).
   function Float_Guard (Of_Target : Target) return String;

   function Convention (Of_Target : Target) return String;

   --  `lp64` or `ilp32`, as the policy's `abi.data_model` names it.
   function Data_Model (Of_Target : Target) return String;

   --  The refine target a row binds for, as Landin.Targets describes it:
   --  its pointer's width and the greatest object it can hold are read
   --  from there and spelled nowhere else.
   function Facts (Of_Target : Target) return Landin.Targets.Target_Facts;

   --  The bytes of a C long, a pointer and a size_t.
   function Word_Size (Of_Target : Target) return Positive;

   function Unsigned_Char (Of_Target : Target) return Boolean;

   --  A freestanding target has no C library: Clang gets no system root,
   --  and an adapter that would need malloc or a thread pointer is refused
   --  (D937, D938).
   function Hosted (Of_Target : Target) return Boolean;

   --  What Clang is given beside the triple to select the row's float
   --  ABI and freestanding environment.
   function Clang_Options (Of_Target : Target)
     return Landin.Platform.Path_List;

   --  The outputs, in the order they are replaced.
   Output_Count : constant := 4;

   subtype Output_Index is Positive range 1 .. Output_Count;

   function Output_Name (Index : Output_Index) return String;

   --  What went wrong, each kind its own diagnostic code.
   type Fault_Kind is
     (No_Fault,
      --  The policy is not JSON, or not a binding policy.
      Policy_Fault,
      --  Clang selected another target, describes another ABI, or printed
      --  what is not an AST or a probe's answer.
      Clang_Fault,
      --  A selected declaration, or its policy, cannot be bound.
      Declaration_Fault);

   type Session is limited private;

   function Ok (Of_Session : Session) return Boolean;

   function Fault (Of_Session : Session) return Fault_Kind;

   function Message (Of_Session : Session) return String;

   --  The policy's bytes, as `--policy` names them.
   procedure Load_Policy (Into : in out Session; Text : String);

   --  The triple the policy's `abi.target` names.
   function Policy_Triple (Of_Session : Session) return String
     with Pre => Ok (Of_Session);

   --  The row the policy's `abi.target` names.
   function Policy_Target (Of_Session : Session) return Target
     with Pre => Ok (Of_Session);

   --  What Clang printed for `-print-target-triple`: the target's triple.
   procedure Check_Triple
     (Into          : in out Session;
      For_Target    : Target;
      Triple_Output : String);

   --  What Clang printed for `-dM -E` of an empty C file: the target's
   --  data model, little-endian, with the target's macros and the sign of
   --  its plain char.
   procedure Check_Macros
     (Into       : in out Session;
      For_Target : Target;
      Macros     : String);

   --  The preprocessed headers without Clang's line markers, the text the
   --  AST's byte offsets are offsets into.  A marker naming an absolute
   --  path under none of Roots is refused, since a header reached there
   --  could make what is generated depend on where it was.
   procedure Strip_Markers
     (Into         : in out Session;
      Preprocessed : String;
      Roots        : Landin.Platform.Path_List;
      Stripped     : out Ada.Strings.Unbounded.Unbounded_String);

   --  Physical filenames reported by Clang before line markers are removed.
   --  These are dependency-name evidence, not identities of Clang's read FDs.
   function Marker_Files (Preprocessed : String)
      return Landin.Platform.Path_List;

   --  Clang's -MD -MF - output with a fixed -MT target. Decode Make's
   --  filename escaping, continuation lines and doubled dollar signs.
   procedure Dependency_Files
     (Dependencies : String; Files : out Landin.Platform.Path_List;
      Valid : out Boolean);

   --  One selected header: the name `exports.h` includes it by and the
   --  SHA-256 of its bytes.
   type Header is record
      Logical : Ada.Strings.Unbounded.Unbounded_String;
      Digest  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Header_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Header);

   --  Clang's `-ast-dump=json` of the preprocessed headers.  Selects every
   --  declaration the policy names and collects what they depend on.
   procedure Read_Ast
     (Into    : in out Session;
      Ast     : String;
      Headers : Header_Vectors.Vector);

   --  Whether an enum's compatible integer type has to be asked of Clang.
   function Needs_Probe (Of_Session : Session) return Boolean;

   --  The probe's C: the preprocessed headers, with every anonymous enum
   --  given a tag, and one enumerator per enum whose value names its
   --  compatible type.
   procedure Probe_Source
     (Into   : in out Session;
      Text   : String;
      Source : out Ada.Strings.Unbounded.Unbounded_String);

   --  The `-ast-dump-filter` argument that dumps only the probe's answers.
   function Probe_Filter (Of_Session : Session) return String;

   --  Clang's dump of those answers, one JSON object per enumerator.
   procedure Read_Probe (Into : in out Session; Output : String);

   --  Render the four outputs.  Defines are the `--define` values, NAME
   --  or NAME=VALUE, whose names and hashes the metadata records.
   procedure Generate
     (Into    : in out Session;
      Defines : Landin.Platform.Path_List);

   function Output
     (Of_Session : Session; Index : Output_Index) return String
     with Pre => Ok (Of_Session);

   --  Spellings the command checks a request against.
   function Is_C_Identifier (Text : String) return Boolean;

   --  Python's repr of a string, which is how every message quotes a name.
   function Quoted (Text : String) return String;

private

   package US renames Ada.Strings.Unbounded;
   package J renames Landin.Json;

   Binding_Error : exception;

   use type J.Value;

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   package String_Sets is new Ada.Containers.Indefinite_Ordered_Sets
     (Element_Type => String);

   package Value_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => J.Value);

   package Value_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => J.Value);

   package Index_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Positive);

   package Natural_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Natural);

   package Text_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => String);

   package Value_List_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Value_Vectors.Vector,
      "=" => Value_Vectors."=");

   ---------------------------------------------------------------------
   --  C types, as the generator reads them out of Clang's AST
   ---------------------------------------------------------------------

   type Type_Kind is
     (Builtin_Type, Pointer_Type, Callback_Type, Function_Type, Array_Type,
      Record_Type, Enum_Type, Alias_Type, Unsupported_Type);

   type Type_Id is new Natural;

   No_Type : constant Type_Id := 0;

   package Type_Lists is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Type_Id);

   --  Never changed once made: a type with another qualifier is a new one.
   type C_Type is record
      Kind        : Type_Kind := Unsupported_Type;
      Spelling    : US.Unbounded_String;
      --  A builtin's canonical spelling, a record's or enum's declaration
      --  identity, an alias's typedef name, or why a type is unsupported.
      Name        : US.Unbounded_String;
      Const       : Boolean := False;
      Child       : Type_Id := No_Type;
      --  An array's extent; -1 for one C leaves unwritten.
      Count       : Long_Long_Integer := 0;
      Result      : Type_Id := No_Type;
      Parameters  : Type_Lists.Vector;
      Variadic    : Boolean := False;
      Old_Style   : Boolean := False;
      Declaration : US.Unbounded_String;
   end record;

   package Type_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => C_Type);

   type Record_Info is record
      Node     : J.Value := J.No_Value;
      Identity : US.Unbounded_String;
      Tag      : US.Unbounded_String;
      Typedef_Names : String_Vectors.Vector;
   end record;

   package Record_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Record_Info);

   type Enum_Info is record
      Node     : J.Value := J.No_Value;
      Identity : US.Unbounded_String;
      Tag      : US.Unbounded_String;
      Typedef_Names : String_Vectors.Vector;
      Compatible : US.Unbounded_String;
      Has_Compatible : Boolean := False;
   end record;

   package Enum_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Enum_Info);

   ---------------------------------------------------------------------
   --  The policy
   ---------------------------------------------------------------------

   type Entry_Kind is
     (Alias_Entry, Callback_Entry, Enum_Entry, Function_Entry,
      Incoming_Entry, Record_Entry, Variable_Entry);

   type Policy_Entry is record
      Kind        : Entry_Kind := Alias_Entry;
      Name        : US.Unbounded_String;
      Landin_Name : US.Unbounded_String;
      Raw         : J.Value := J.No_Value;
      Index       : Positive := 1;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Policy_Entry);

   --  A reference position's policy (`bindings/README.md`).
   type Annotation is record
      Present     : Boolean := False;
      Ownership   : US.Unbounded_String;
      Nullability : US.Unbounded_String;
      Retention   : US.Unbounded_String;
      From        : String_Vectors.Vector;
   end record;

   No_Annotation : constant Annotation := (others => <>);

   package Annotation_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Annotation);

   ---------------------------------------------------------------------
   --  The metadata, a JSON tree written with sorted keys
   ---------------------------------------------------------------------

   type Meta_Kind is
     (Meta_Null, Meta_True, Meta_False, Meta_Number, Meta_String,
      Meta_List, Meta_Object);

   type Meta_Id is new Positive;

   type Meta_Member is record
      Key  : US.Unbounded_String;
      Item : Meta_Id;
   end record;

   package Member_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Meta_Member);

   type Meta_Node is record
      Kind    : Meta_Kind := Meta_Null;
      Text    : US.Unbounded_String;
      Members : Member_Vectors.Vector;
   end record;

   package Meta_Vectors is new Ada.Containers.Vectors
     (Index_Type => Meta_Id, Element_Type => Meta_Node);

   package Meta_Lists is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Meta_Id);

   ---------------------------------------------------------------------
   --  The generator's own records
   ---------------------------------------------------------------------

   type C_Function is record
      Result     : US.Unbounded_String;
      Name       : US.Unbounded_String;
      Parameters : String_Vectors.Vector;
      Body_Lines : String_Vectors.Vector;
   end record;

   package Function_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => C_Function);

   type Optional_Type is record
      Name        : US.Unbounded_String;
      Absent      : US.Unbounded_String;
      Member_Type : US.Unbounded_String;
   end record;

   package Optional_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Optional_Type);

   --  A selected function, incoming entry or variable and its node.
   type Selection is record
      Choice : Positive;
      Node   : J.Value;
   end record;

   package Selection_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Selection);

   type Dependency is record
      Is_Record : Boolean;
      Is_Callback : Boolean;
      Name : US.Unbounded_String;
   end record;

   package Dependency_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Dependency);

   type Phase is
     (Starting, Policy_Loaded, Target_Checked, Ast_Read, Probed, Generated);

   --  Everything a session holds, reached through a handle so that a
   --  function may add to it without an `in out` view of the session.
   type Session_State is limited record
      Stage     : Phase := Starting;
      Failed    : Boolean := False;
      Kind      : Fault_Kind := No_Fault;
      Problem   : US.Unbounded_String;

      --  The policy.
      Policy_Document : J.Document;
      Namespace : US.Unbounded_String;
      Target_Triple : US.Unbounded_String;
      Chosen    : Target := Linux_X86_64;
      Entries   : Entry_Vectors.Vector;
      Policy_Digest : US.Unbounded_String;

      --  Clang's AST, and what was read out of it.
      Ast       : J.Document;
      Headers   : Header_Vectors.Vector;
      Typedef_Order : String_Vectors.Vector;
      Typedefs  : Value_Maps.Map;
      Typedefs_By_Id : Value_Maps.Map;
      Functions : Value_List_Maps.Map;
      Variables : Value_List_Maps.Map;
      Records   : Record_Vectors.Vector;
      Enums     : Enum_Vectors.Vector;
      Identifiers : String_Sets.Set;
      Records_By_Id : Index_Maps.Map;
      Enums_By_Id : Index_Maps.Map;
      Records_By_Tag : Index_Maps.Map;
      Enums_By_Tag : Index_Maps.Map;
      Records_By_Typedef : Index_Maps.Map;
      Enums_By_Typedef : Index_Maps.Map;

      --  Every type made, and each typedef's target once read.
      Types     : Type_Vectors.Vector;
      Alias_Cache : Natural_Maps.Map;
      Alias_Stack : String_Sets.Set;

      --  The generator.
      Record_Entries : Index_Maps.Map;
      Enum_Entries : Index_Maps.Map;
      Callback_Entries : Index_Maps.Map;
      Alias_Entries : Index_Maps.Map;
      Function_Entries : Selection_Vectors.Vector;
      Variable_Entries : Selection_Vectors.Vector;
      Incoming_Entries : Selection_Vectors.Vector;
      Annotations : Annotation_Maps.Map;
      Needed_Records : String_Sets.Set;
      Needed_Enums : String_Sets.Set;
      Needed_Aliases : String_Sets.Set;
      Needed_Callbacks : String_Sets.Set;
      Pending : Dependency_Vectors.Vector;
      Next_Pending : Positive := 1;
      Classifications : Text_Maps.Map;
      Roots_Collected : Boolean := False;
      Optionals : Optional_Maps.Map;
      C_Functions : Function_Vectors.Vector;
      C_Definitions : String_Vectors.Vector;
      C_Assertions : String_Vectors.Vector;
      Export_Declarations : String_Vectors.Vector;
      Type_Blocks : String_Vectors.Vector;
      Declarations : String_Vectors.Vector;
      Meta : Meta_Vectors.Vector;
      Meta_Declarations : Meta_Lists.Vector;
      Needs_Stdlib : Boolean := False;
      Needs_Stdarg : Boolean := False;
      Landin_Names : Text_Maps.Map;
      C_Symbols : String_Sets.Set;
      Cell_Structs : Text_Maps.Map;

      --  The enum probe: the enums asked about, in order, and the prefix
      --  of every name it adds.
      Probed_Enums : String_Vectors.Vector;
      Probe_Prefix : US.Unbounded_String;

      Outputs : String_Vectors.Vector;
   end record;

   type State_Access is access Session_State;

   subtype Handle is not null State_Access;

   type Session is new Ada.Finalization.Limited_Controlled with record
      Data : Handle := new Session_State;
   end record;

   overriding procedure Finalize (Item : in out Session);

   --  Record why the session ends and raise Binding_Error.
   procedure Fail
     (Within : Handle; Message : String;
      Kind : Fault_Kind := Declaration_Fault)
     with No_Return;

end Landin.Bindings;
