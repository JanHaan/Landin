with Ada.Strings.Fixed;
with GNAT.SHA256;
with Landin.Bindings.Clang;
with Landin.Bindings.Policies;
with Landin.Bindings.Texts;

package body Landin.Bindings.Generation is

   package C renames Landin.Bindings.Clang;
   package P renames Landin.Bindings.Policies;
   package T renames Landin.Bindings.Texts;

   function "&" (Left : String_Vectors.Vector; Right : String)
     return String_Vectors.Vector renames String_Vectors."&";
   function "&" (Left, Right : String_Vectors.Vector)
     return String_Vectors.Vector renames String_Vectors."&";

   LF : constant Character := ASCII.LF;

   Native_Layout : constant String := "native-layout-c";
   Opaque_Storage : constant String := "c-owned-opaque";
   Incomplete : constant String := "incomplete-opaque";

   ---------------------------------------------------------------------
   --  Small readers
   ---------------------------------------------------------------------

   function Get (S : Handle; Id : Type_Id) return C_Type renames C.Get;

   function Kind (S : Handle; Id : Type_Id) return Type_Kind is
     (Get (S, Id).Kind);

   function Name (S : Handle; Id : Type_Id) return String is
     (US.To_String (Get (S, Id).Name));

   function Spelling (S : Handle; Id : Type_Id) return String is
     (US.To_String (Get (S, Id).Spelling));

   function Is_Void (S : Handle; Id : Type_Id) return Boolean is
     (Kind (S, Id) = Builtin_Type and then Name (S, Id) = "void");

   function Find (Map : Index_Maps.Map; Key : String) return Natural is
     (if Map.Contains (Key) then Map (Key) else 0);

   function Context (S : Handle; Choice : Positive) return String is
     (P.Context (S.Entries (Choice)));

   function Raw (S : Handle; Choice : Positive) return J.Value is
     (S.Entries (Choice).Raw);

   function Entry_Name (S : Handle; Choice : Positive) return String is
     (US.To_String (S.Entries (Choice).Name));

   function Entry_Landin (S : Handle; Choice : Positive) return String is
     (US.To_String (S.Entries (Choice).Landin_Name));

   function Lookup (Map : Annotation_Maps.Map; Key : String)
     return Annotation is
     (if Map.Contains (Key) then Map (Key) else No_Annotation);

   function Retaining (Item : Annotation) return Boolean is
     (Item.Present
      and then US.To_String (Item.Retention) in "stored" | "returned"
                                               | "static");

   function Nullable (Item : Annotation) return Boolean is
     (Item.Present and then US.To_String (Item.Nullability) = "nullable");

   function Image (Value : Long_Long_Integer) return String renames T.Image;

   function Number (Value : Natural) return String is
     (T.Image (Long_Long_Integer (Value)));

   --  A position as a key that sorts as the number does.
   function Padded (Value : Natural) return String;

   function Padded (Value : Natural) return String is
      Text : constant String := Number (Value);
   begin
      return [1 .. 10 - Text'Length => '0'] & Text;
   end Padded;

   function Field_Key (Identity, Field : String) return String is
     (Identity & ASCII.NUL & Field);

   --  A field's name, or its position when it has none, as a message
   --  names it.
   function Field_Label (S : Handle; Field : J.Value; Index : Positive)
     return String is
     (if C.Text (S, Field, "name") /= "" then C.Text (S, Field, "name")
      else Number (Index));

   function Parameters_Of (S : Handle; Node : J.Value)
     return Value_Vectors.Vector;

   function Parameters_Of (S : Handle; Node : J.Value)
     return Value_Vectors.Vector
   is
      Result : Value_Vectors.Vector;
   begin
      for Item of C.Inner (S, Node) loop
         if C.Text (S, Item, "kind") = "ParmVarDecl" then
            Result.Append (Item);
         end if;
      end loop;
      return Result;
   end Parameters_Of;

   function Parameter_Name
     (S : Handle; Node : J.Value; Index : Positive) return String is
     (if C.Text (S, Node, "name") /= "" then C.Text (S, Node, "name")
      else "argument_" & Number (Index));

   function Type_Of (S : Handle; Node : J.Value) return Type_Id is
     (C.From_Info (S, C.Field (S, Node, "type")));

   function Has_Body (S : Handle; Node : J.Value) return Boolean is
     (for some Item of C.Inner (S, Node) =>
        C.Text (S, Item, "kind") = "CompoundStmt");

   --  The keys of a policy object, as a set.
   function Key_Set (S : Handle; Item : J.Value) return String_Sets.Set;

   function Key_Set (S : Handle; Item : J.Value) return String_Sets.Set is
      Result : String_Sets.Set;
   begin
      for Key of P.Keys (S, Item) loop
         Result.Include (Key);
      end loop;
      return Result;
   end Key_Set;

   function Builtin_Landin (Canonical : String) return String is
     (if Canonical = "char" then "c.c_char"
      elsif Canonical = "signed char" then "c.c_schar"
      elsif Canonical = "unsigned char" then "c.c_uchar"
      elsif Canonical = "short" then "c.c_short"
      elsif Canonical = "unsigned short" then "c.c_ushort"
      elsif Canonical = "int" then "c.c_int"
      elsif Canonical = "unsigned int" then "c.c_uint"
      elsif Canonical = "long" then "c.c_long"
      elsif Canonical = "unsigned long" then "c.c_ulong"
      elsif Canonical = "long long" then "c.c_longlong"
      elsif Canonical = "unsigned long long" then "c.c_ulonglong"
      elsif Canonical = "float" then "c.c_float"
      elsif Canonical = "double" then "c.c_double"
      elsif Canonical = "_Bool" then "c.c_bool" else "");

   --  A builtin's size, which is also its alignment, or zero: a long is
   --  the target's word, four bytes under ILP32 and eight under LP64.
   function Builtin_Size (S : Handle; Canonical : String) return Natural is
     (if Canonical in "char" | "signed char" | "unsigned char" | "_Bool"
      then 1
      elsif Canonical in "short" | "unsigned short" then 2
      elsif Canonical in "int" | "unsigned int" | "float" then 4
      elsif Canonical in "long" | "unsigned long" then Word_Size (S.Chosen)
      elsif Canonical in "long long" | "unsigned long long" | "double"
      then 8
      else 0);

   ---------------------------------------------------------------------
   --  Forward declarations
   ---------------------------------------------------------------------

   function Resolve (S : Handle; Id : Type_Id) return Type_Id;
   function Contains_Reference
     (S : Handle; Id : Type_Id;
      Visiting : String_Sets.Set := String_Sets.Empty_Set) return Boolean;
   procedure Ensure_Supported
     (S : Handle; Id : Type_Id; Context : String;
      Allow_Void : Boolean := False);
   function Record_Classification (S : Handle; Index : Positive)
     return String;
   function Flexible_Field (S : Handle; Index : Positive) return J.Value;
   function Layout_Size (S : Handle; Id : Type_Id) return Natural;
   function Layout_Alignment (S : Handle; Id : Type_Id) return Natural;
   function Pointer_Only
     (S : Handle; Id : Type_Id;
      Visiting : String_Sets.Set := String_Sets.Empty_Set) return Boolean;
   function Landin_Type
     (S : Handle; Id : Type_Id; Note : Annotation := No_Annotation;
      Site : String := "value"; Pointer_As_Opaque : Boolean := False)
      return String;
   function Landin_Return
     (S : Handle; Id : Type_Id; Note : Annotation; Site : String;
      Result_Name : String := "result") return String;

   --  C parameters and tags occupy different namespaces. Landin signature
   --  bindings share the namespace of the types they refer to, so allocate
   --  the complete signature together before writing any of its bindings.
   type Landin_Signature is record
      Parameters : String_Vectors.Vector;
      Result : US.Unbounded_String;
      Names : Text_Maps.Map;
   end record;

   function Signature
     (Parameters : String_Vectors.Vector; Result : String)
      return Landin_Signature;

   function C_Type_Text (S : Handle; Id : Type_Id) return String;
   function C_Declarator
     (S : Handle; Id : Type_Id; Declared : String) return String;

   ---------------------------------------------------------------------
   --  Names
   ---------------------------------------------------------------------

   procedure Claim_Landin (S : Handle; Name : String; Context : String);

   procedure Claim_Landin (S : Handle; Name : String; Context : String) is
   begin
      if S.Landin_Names.Contains (Name) then
         Fail (S, Context & ": Landin name " & T.Repr (Name)
               & " collides with " & S.Landin_Names (Name));
      end if;
      S.Landin_Names.Insert (Name, Context);
   end Claim_Landin;

   function Claim_Generated_Landin
     (S : Handle; Name : String; Context : String) return String;

   function Claim_Generated_Landin
     (S : Handle; Name : String; Context : String) return String
   is
      Clean : constant String := T.Sanitize_Landin (Name);
   begin
      Claim_Landin (S, Clean, Context);
      return Clean;
   end Claim_Generated_Landin;

   --  Python's repr of a tuple of strings.
   function Tuple_Repr (Parts : String_Vectors.Vector) return String;

   function Tuple_Repr (Parts : String_Vectors.Vector) return String is
      Quoted : String_Vectors.Vector;
   begin
      for Part of Parts loop
         Quoted.Append (T.Repr (Part));
      end loop;
      return "(" & T.Join (Quoted, ", ")
        & (if Natural (Parts.Length) = 1 then "," else "") & ")";
   end Tuple_Repr;

   function C_Symbol (S : Handle; Parts : String_Vectors.Vector)
     return String;

   function C_Symbol (S : Handle; Parts : String_Vectors.Vector)
     return String
   is
      Clean : String_Vectors.Vector;
   begin
      for Part of Parts loop
         Clean.Append (T.Symbol_Part (Part));
      end loop;
      declare
         Symbol : constant String :=
           "landin_" & US.To_String (S.Namespace) & "_" & T.Join (Clean, "_");
      begin
         if not Is_C_Identifier (Symbol) then
            Fail (S, "cannot form adapter symbol from " & Tuple_Repr (Parts));
         end if;
         if S.C_Symbols.Contains (Symbol) then
            Fail (S, "generated C symbol collision: " & Symbol);
         end if;
         S.C_Symbols.Insert (Symbol);
         return Symbol;
      end;
   end C_Symbol;

   function C_Symbol (S : Handle; First, Second : String) return String is
     (C_Symbol (S, String_Vectors.To_Vector (First, 1) & Second));

   --  Locals of a generated C function, clear of every header identifier,
   --  every generated symbol and each other.
   function C_Locals (S : Handle; Names : String_Vectors.Vector)
     return String_Vectors.Vector;

   function C_Locals (S : Handle; Names : String_Vectors.Vector)
     return String_Vectors.Vector
   is
      Used : String_Sets.Set;
      Result : String_Vectors.Vector;
   begin
      for Wanted of Names loop
         declare
            Chosen : US.Unbounded_String := US.To_Unbounded_String (Wanted);
         begin
            while Used.Contains (US.To_String (Chosen))
              or else S.Identifiers.Contains (US.To_String (Chosen))
              or else S.C_Symbols.Contains (US.To_String (Chosen))
            loop
               US.Append (Chosen, "_");
            end loop;
            Used.Include (US.To_String (Chosen));
            Result.Append (US.To_String (Chosen));
         end;
      end loop;
      return Result;
   end C_Locals;

   function C_Local (S : Handle; Name : String) return String is
     (C_Locals (S, String_Vectors.To_Vector (Name, 1)).First_Element);

   procedure Ensure_Typedef_Unattributed
     (S : Handle; Name : String; Context : String);

   procedure Ensure_Typedef_Unattributed
     (S : Handle; Name : String; Context : String) is
   begin
      for Item of C.Inner (S, S.Typedefs (Name)) loop
         if T.Ends_With (C.Text (S, Item, "kind"), "Attr") then
            Fail (S, Context & ": unsupported typedef attribute "
                  & C.Text (S, Item, "kind"));
         end if;
      end loop;
   end Ensure_Typedef_Unattributed;

   ---------------------------------------------------------------------
   --  Types
   ---------------------------------------------------------------------

   function Resolve (S : Handle; Id : Type_Id) return Type_Id is
      Seen : String_Sets.Set;
      Current : Type_Id := Id;
      Qualified : Boolean := Get (S, Id).Const;
   begin
      while Kind (S, Current) = Alias_Type loop
         if Seen.Contains (Name (S, Current)) then
            Fail (S, "recursive typedef " & T.Repr (Name (S, Current)));
         end if;
         Seen.Include (Name (S, Current));
         if Get (S, Current).Child = No_Type then
            Fail (S, "typedef " & T.Repr (Name (S, Current))
                  & " has no target");
         end if;
         Current := Get (S, Current).Child;
         Qualified := Qualified or else Get (S, Current).Const;
      end loop;
      if Qualified and then not Get (S, Current).Const then
         return C.With_Const (S, Current, True);
      end if;
      return Current;
   end Resolve;

   function Resolved_Kind (S : Handle; Id : Type_Id) return Type_Kind is
     (Kind (S, Resolve (S, Id)));

   function Record_For (S : Handle; Id : Type_Id) return Positive;

   function Record_For (S : Handle; Id : Type_Id) return Positive is
      Resolved : constant Type_Id := Resolve (S, Id);
   begin
      if Kind (S, Resolved) /= Record_Type
        or else not S.Records_By_Id.Contains (Name (S, Resolved))
      then
         Fail (S, "internal: missing record for " & Spelling (S, Id));
      end if;
      return S.Records_By_Id (Name (S, Resolved));
   end Record_For;

   function Enum_For (S : Handle; Id : Type_Id) return Positive;

   function Enum_For (S : Handle; Id : Type_Id) return Positive is
      Resolved : constant Type_Id := Resolve (S, Id);
   begin
      if Kind (S, Resolved) /= Enum_Type
        or else not S.Enums_By_Id.Contains (Name (S, Resolved))
      then
         Fail (S, "internal: missing enum for " & Spelling (S, Id));
      end if;
      return S.Enums_By_Id (Name (S, Resolved));
   end Enum_For;

   function Record_Display (S : Handle; Index : Positive) return String is
     (T.Repr (C.Record_Display (S, Index)));

   function Contains_Reference
     (S : Handle; Id : Type_Id;
      Visiting : String_Sets.Set := String_Sets.Empty_Set) return Boolean
   is
      Resolved : constant Type_Id := Resolve (S, Id);
   begin
      case Kind (S, Resolved) is
         when Pointer_Type | Callback_Type =>
            return True;
         when Array_Type =>
            return Get (S, Resolved).Child /= No_Type
              and then Contains_Reference
                (S, Get (S, Resolved).Child, Visiting);
         when Record_Type =>
            if Visiting.Contains (Name (S, Resolved)) then
               return False;
            end if;
            declare
               Nested : String_Sets.Set := Visiting;
               Index : constant Positive :=
                 C.Record_Index (S, Name (S, Resolved));
            begin
               Nested.Include (Name (S, Resolved));
               for Field of C.Record_Fields (S, Index) loop
                  if Contains_Reference (S, Type_Of (S, Field), Nested) then
                     return True;
                  end if;
               end loop;
               return False;
            end;
         when others =>
            return False;
      end case;
   end Contains_Reference;

   procedure Ensure_Supported
     (S : Handle; Id : Type_Id; Context : String;
      Allow_Void : Boolean := False)
   is
      Resolved : constant Type_Id := Resolve (S, Id);
      Item : constant C_Type := Get (S, Resolved);
   begin
      case Item.Kind is
         when Unsupported_Type =>
            Fail (S, Context & ": unsupported " & US.To_String (Item.Name)
                  & ": " & US.To_String (Item.Spelling));
         when Builtin_Type =>
            if US.To_String (Item.Name) = "void" and then not Allow_Void then
               Fail (S, Context & ": void is not a value type");
            end if;
         when Pointer_Type =>
            if Item.Child = No_Type then
               Fail (S, Context & ": pointer has no pointee");
            end if;
            declare
               Pointee : constant Type_Id := Resolve (S, Item.Child);
            begin
               if Kind (S, Pointee) = Function_Type then
                  Fail (S, Context & ": unsupported unprototyped or unnamed"
                        & " function pointer");
               end if;
               if Kind (S, Pointee) = Callback_Type
                 and then Kind (S, Item.Child) /= Alias_Type
               then
                  Fail (S, Context & ": pointer to an unnamed function-pointer"
                        & " cell is unsupported");
               end if;
               if Kind (S, Pointee) = Unsupported_Type then
                  Fail (S, Context & ": unsupported pointer pointee "
                        & Name (S, Pointee) & ": " & Spelling (S, Pointee));
               end if;
            end;
         when Callback_Type =>
            if Item.Old_Style then
               Fail (S, Context & ": old-style function type is unsupported");
            end if;
            if Item.Variadic and then Item.Parameters.Is_Empty then
               Fail (S, Context & ": variadic callback needs at least one"
                     & " fixed parameter");
            end if;
            declare
               Inner_References : Boolean :=
                 Contains_Reference (S, Item.Result);
            begin
               for Parameter of Item.Parameters loop
                  exit when Inner_References;
                  Inner_References := Contains_Reference (S, Parameter);
               end loop;
               if Inner_References and then Kind (S, Id) /= Alias_Type then
                  Fail (S, Context & ": anonymous callback with reference"
                        & " positions requires an explicitly annotated named"
                        & " callback typedef");
               end if;
            end;
            Ensure_Supported (S, Item.Result, Context & " result",
                              Allow_Void => True);
            for Position in 1 .. Natural (Item.Parameters.Length) loop
               Ensure_Supported (S, Item.Parameters (Position),
                                 Context & " parameter" & Positive'Image
                                   (Position));
            end loop;
         when Array_Type =>
            if Item.Count <= 0 then
               Fail (S, Context & ": flexible or zero-size array is"
                     & " unsupported");
            end if;
            Ensure_Supported (S, Item.Child, Context & " element");
         when Record_Type =>
            declare
               Index : constant Positive := Record_For (S, Resolved);
            begin
               if not C.Record_Complete (S, Index) then
                  Fail (S, Context & ": incomplete record is not a by-value"
                        & " type");
               end if;
               if J.Is_Present (Flexible_Field (S, Index)) then
                  Fail (S, Context & ": record " & Record_Display (S, Index)
                        & " ends in a flexible array member, whose elements"
                        & " are not part of its value; C reaches it only"
                        & " through a pointer (D413, D414)");
               end if;
            end;
         when Enum_Type =>
            if C.Enum_Constants (S, Enum_For (S, Resolved)).Is_Empty then
               Fail (S, Context & ": empty enum is unsupported");
            end if;
         when others =>
            Fail (S, Context & ": unsupported type "
                  & US.To_String (Item.Spelling));
      end case;
   end Ensure_Supported;

   function Function_Result
     (S : Handle; Node : J.Value; Context : String) return Type_Id;

   function Function_Result
     (S : Handle; Node : J.Value; Context : String) return Type_Id
   is
      Info : constant J.Value := C.Field (S, Node, "type");
      Found : Boolean;
      Result_Text, Parameter_Text : US.Unbounded_String;
   begin
      if not J.Is_Kind (S.Ast, C.Field (S, Info, "qualType"), J.String_Value)
      then
         Fail (S, Context & ": Clang function type is missing");
      end if;
      C.Split_Function
        (C.Text (S, Info, "qualType"), Found, Result_Text, Parameter_Text);
      if not Found then
         Fail (S, Context & ": unsupported nested function return declarator "
               & T.Repr (C.Text (S, Info, "qualType"))
               & "; use a named callback typedef");
      end if;
      return C.Parse (S, US.To_String (Result_Text));
   end Function_Result;

   --  `( )` at the end of a function's spelling, an old-style declaration.
   function Ends_In_Empty_List (Text : String) return Boolean;

   function Ends_In_Empty_List (Text : String) return Boolean is
      Last : Natural := Text'Last;
   begin
      while Last >= Text'First and then T.Is_Space (Text (Last)) loop
         Last := Last - 1;
      end loop;
      if Last < Text'First or else Text (Last) /= ')' then
         return False;
      end if;
      Last := Last - 1;
      while Last >= Text'First and then T.Is_Space (Text (Last)) loop
         Last := Last - 1;
      end loop;
      return Last >= Text'First and then Text (Last) = '(';
   end Ends_In_Empty_List;

   procedure Validate_Function_Shape
     (S : Handle; Choice : Positive; Node : J.Value;
      Params : out Value_Vectors.Vector; Result : out Type_Id);

   procedure Validate_Function_Shape
     (S : Handle; Choice : Positive; Node : J.Value;
      Params : out Value_Vectors.Vector; Result : out Type_Id)
   is
      Where : constant String := Context (S, Choice);
      Text : constant String :=
        C.Text (S, C.Field (S, Node, "type"), "qualType");
      Names : String_Sets.Set;

      procedure Validate_Attributes (Value : J.Value);

      procedure Validate_Attributes (Value : J.Value) is
         Value_Kind : constant String := C.Text (S, Value, "kind");
      begin
         if Value_Kind = "CompoundStmt" then
            return;
         end if;
         if T.Ends_With (Value_Kind, "Attr") then
            Fail (S, Where & ": unsupported calling convention or"
                  & " parameter/function attribute " & Value_Kind);
         end if;
         for Child of C.Inner (S, Value) loop
            Validate_Attributes (Child);
         end loop;
      end Validate_Attributes;
   begin
      Params := Parameters_Of (S, Node);
      for Index in 1 .. Natural (Params.Length) loop
         declare
            Clean : constant String :=
              T.Sanitize_Landin (Parameter_Name (S, Params (Index), Index));
         begin
            if Names.Contains (Clean) then
               Fail (S, Where & ": parameter names collide after Landin"
                     & " normalization");
            end if;
            Names.Include (Clean);
         end;
      end loop;
      if Params.Is_Empty and then Ends_In_Empty_List (Text) then
         Fail (S, Where & ": old-style function declaration is unsupported");
      end if;
      if T.Contains (Text, "__attribute__") then
         Fail (S, Where & ": unsupported calling convention or function type"
               & " attribute: " & Text);
      end if;
      Validate_Attributes (Node);
      Result := Function_Result (S, Node, Where);
      Ensure_Supported (S, Result, Where & " result", Allow_Void => True);
      for Index in 1 .. Natural (Params.Length) loop
         Ensure_Supported
           (S, Type_Of (S, Params (Index)),
            Where & " parameter " & Field_Label (S, Params (Index), Index));
      end loop;
   end Validate_Function_Shape;

   procedure Validate_Site_Annotations
     (S : Handle; Choice : Positive; Params : Value_Vectors.Vector;
      Result : Type_Id; Notes : out Annotation_Maps.Map;
      Result_Note : out Annotation);

   procedure Validate_Site_Annotations
     (S : Handle; Choice : Positive; Params : Value_Vectors.Vector;
      Result : Type_Id; Notes : out Annotation_Maps.Map;
      Result_Note : out Annotation)
   is
      Where : constant String := Context (S, Choice);
      Raw_Parameters : constant J.Value :=
        P.Field (S, Raw (S, Choice), "parameters");
      Policy_Names : constant String_Sets.Set := Key_Set (S, Raw_Parameters);
      Actual : String_Sets.Set;
   begin
      Notes.Clear;
      Result_Note := No_Annotation;
      for Index in 1 .. Natural (Params.Length) loop
         declare
            C_Name : constant String :=
              Parameter_Name (S, Params (Index), Index);
            Item : constant Type_Id := Type_Of (S, Params (Index));
         begin
            Actual.Include (C_Name);
            if Contains_Reference (S, Item) then
               if not Policy_Names.Contains (C_Name) then
                  Fail (S, Where & " parameter " & T.Repr (C_Name)
                        & ": missing required pointer policy");
               end if;
               declare
                  Note : constant Annotation :=
                    P.Annotation_Of
                      (S, P.Field (S, Raw_Parameters, C_Name),
                       Where & " parameter " & T.Repr (C_Name));
               begin
                  Notes.Include (C_Name, Note);
                  if not Note.From.Is_Empty then
                     Fail (S, Where & " parameter " & T.Repr (C_Name)
                           & ": from must be empty");
                  end if;
               end;
            elsif Policy_Names.Contains (C_Name) then
               Fail (S, Where & " parameter " & T.Repr (C_Name)
                     & ": a non-reference parameter takes no policy;"
                     & " remove " & T.Repr (C_Name) & " from ""parameters""");
            end if;
         end;
      end loop;
      for Key of Policy_Names loop
         if not Actual.Contains (Key) then
            Fail (S, Where & ": parameter " & T.Repr (Key)
                  & " is absent from header (stale policy)");
         end if;
      end loop;
      if Contains_Reference (S, Result) then
         if not P.Has (S, Raw (S, Choice), "result") then
            Fail (S, Where & " result: missing required pointer policy");
         end if;
         Result_Note := P.Annotation_Of
           (S, P.Field (S, Raw (S, Choice), "result"), Where & " result");
         declare
            Unknown : String_Sets.Set;
         begin
            for Source of Result_Note.From loop
               if not Actual.Contains (Source) then
                  Unknown.Include (Source);
               end if;
            end loop;
            if not Unknown.Is_Empty then
               Fail (S, Where & " result: from names absent parameter "
                     & T.Repr (Unknown.First_Element));
            end if;
         end;
         if (for some Source of Result_Note.From =>
               not Notes.Contains (Source))
         then
            Fail (S, Where & " result: from must name reference-bearing"
                  & " parameters");
         end if;
      elsif P.Has (S, Raw (S, Choice), "result") then
         Fail (S, Where & " result: a non-reference result takes no"
               & " policy; remove the ""result"" key");
      end if;
   end Validate_Site_Annotations;

   function Enum_Underlying (S : Handle; Index : Positive) return Type_Id;

   function Enum_Underlying (S : Handle; Index : Positive) return Type_Id is
   begin
      if C.Enum_Constants (S, Index).Is_Empty then
         Fail (S, "enum " & T.Repr (C.Enum_Display (S, Index))
               & ": empty enum is unsupported");
      end if;
      if not S.Enums (Index).Has_Compatible then
         Fail (S, "enum " & T.Repr (C.Enum_Display (S, Index))
               & ": compatible integer type was not queried from Clang");
      end if;
      return C.Parse (S, US.To_String (S.Enums (Index).Compatible));
   end Enum_Underlying;

   --  Each constant's name and value: its ConstantExpr's, or one more
   --  than the one before.
   procedure Enum_Values
     (S : Handle; Index : Positive; Names, Values : out String_Vectors.Vector);

   procedure Enum_Values
     (S : Handle; Index : Positive; Names, Values : out String_Vectors.Vector)
   is
      Previous : US.Unbounded_String := US.To_Unbounded_String ("-1");
   begin
      Names.Clear;
      Values.Clear;
      for Constant_Node of C.Enum_Constants (S, Index) loop
         declare
            Found : US.Unbounded_String;
            Has_Found : Boolean := False;

            procedure Walk (Node : J.Value);

            procedure Walk (Node : J.Value) is
            begin
               if Has_Found or else not J.Is_Kind (S.Ast, Node, J.Object_Value)
               then
                  return;
               end if;
               if C.Text (S, Node, "kind") = "ConstantExpr"
                 and then C.Has (S, Node, "value")
               then
                  Found := US.To_Unbounded_String (C.Text (S, Node, "value"));
                  Has_Found := True;
                  return;
               end if;
               for Child of C.Inner (S, Node) loop
                  Walk (Child);
               end loop;
            end Walk;
         begin
            Walk (Constant_Node);
            if Has_Found then
               if not T.Is_Decimal (US.To_String (Found)) then
                  Fail (S, "Clang gave enumerator "
                        & T.Repr (C.Text (S, Constant_Node, "name"))
                        & " the value " & T.Repr (US.To_String (Found)),
                        Clang_Fault);
               end if;
               Previous := US.To_Unbounded_String
                 (T.Canonical (US.To_String (Found)));
            else
               Previous := US.To_Unbounded_String
                 (T.Successor (US.To_String (Previous)));
            end if;
            Names.Append (C.Text (S, Constant_Node, "name"));
            Values.Append (US.To_String (Previous));
         end;
      end loop;
   end Enum_Values;

   function Forbidden_Attribute (S : Handle; Index : Positive) return String;

   function Forbidden_Attribute (S : Handle; Index : Positive) return String
   is
   begin
      for Item of C.Inner (S, S.Records (Index).Node) loop
         declare
            Item_Kind : constant String := C.Text (S, Item, "kind");
         begin
            if T.Ends_With (Item_Kind, "Attr") and then Item_Kind
              /= "PackedAttr"
            then
               return Item_Kind;
            end if;
         end;
      end loop;
      return "";
   end Forbidden_Attribute;

   function Flexible_Field (S : Handle; Index : Positive) return J.Value is
      Fields : constant Value_Vectors.Vector := C.Record_Fields (S, Index);
   begin
      if not C.Record_Complete (S, Index) or else C.Record_Union (S, Index)
        or else Fields.Is_Empty
      then
         return J.No_Value;
      end if;
      declare
         Last : constant Type_Id :=
           Resolve (S, Type_Of (S, Fields.Last_Element));
      begin
         if Kind (S, Last) = Array_Type and then Get (S, Last).Count <= 0 then
            return Fields.Last_Element;
         end if;
      end;
      return J.No_Value;
   end Flexible_Field;

   function Byte_Aligned (S : Handle; Id : Type_Id) return Boolean;

   function Byte_Aligned (S : Handle; Id : Type_Id) return Boolean is
      Resolved : constant Type_Id := Resolve (S, Id);
   begin
      case Kind (S, Resolved) is
         when Builtin_Type =>
            return Builtin_Size (S, Name (S, Resolved)) = 1;
         when Enum_Type =>
            return Layout_Size (S, Resolved) = 1;
         when Array_Type =>
            return Get (S, Resolved).Child /= No_Type
              and then Byte_Aligned (S, Get (S, Resolved).Child);
         when Record_Type =>
            declare
               Index : constant Positive :=
                 C.Record_Index (S, Name (S, Resolved));
            begin
               return C.Record_Complete (S, Index)
                 and then C.Record_Packed (S, Index)
                 and then Record_Classification (S, Index) = Native_Layout;
            end;
         when others =>
            return False;
      end case;
   end Byte_Aligned;

   function Pointer_Only
     (S : Handle; Id : Type_Id;
      Visiting : String_Sets.Set := String_Sets.Empty_Set) return Boolean
   is
      Resolved : constant Type_Id := Resolve (S, Id);
   begin
      if Kind (S, Resolved) = Array_Type then
         return Get (S, Resolved).Child /= No_Type
           and then Pointer_Only (S, Get (S, Resolved).Child, Visiting);
      end if;
      if Kind (S, Resolved) /= Record_Type
        or else Visiting.Contains (Name (S, Resolved))
      then
         return False;
      end if;
      declare
         Index : constant Positive := C.Record_Index (S, Name (S, Resolved));
         Nested : String_Sets.Set := Visiting;
      begin
         if not C.Record_Complete (S, Index)
           or else Record_Classification (S, Index) /= Native_Layout
         then
            return False;
         end if;
         if C.Record_Packed (S, Index)
           or else J.Is_Present (Flexible_Field (S, Index))
         then
            return True;
         end if;
         Nested.Include (Name (S, Resolved));
         for Field of C.Record_Fields (S, Index) loop
            if Pointer_Only (S, Type_Of (S, Field), Nested) then
               return True;
            end if;
         end loop;
         return False;
      end;
   end Pointer_Only;

   function Native_By_Value (S : Handle; Id : Type_Id) return Boolean;

   function Native_By_Value (S : Handle; Id : Type_Id) return Boolean is
      Resolved : constant Type_Id := Resolve (S, Id);
   begin
      case Kind (S, Resolved) is
         when Record_Type =>
            return Record_Classification
              (S, C.Record_Index (S, Name (S, Resolved))) = Native_Layout;
         when Array_Type =>
            return False;
         when Builtin_Type | Pointer_Type | Callback_Type | Enum_Type =>
            return True;
         when others =>
            return False;
      end case;
   end Native_By_Value;

   function Opaque_By_Value (S : Handle; Id : Type_Id) return Boolean;

   function Opaque_By_Value (S : Handle; Id : Type_Id) return Boolean is
      Resolved : constant Type_Id := Resolve (S, Id);
   begin
      return Kind (S, Resolved) = Record_Type
        and then not Native_By_Value (S, Resolved);
   end Opaque_By_Value;

   function By_Address (S : Handle; Id : Type_Id) return Boolean is
     (Opaque_By_Value (S, Id) or else Pointer_Only (S, Id));

   function Landin_Name_For_Record (S : Handle; Index : Positive)
     return String;

   function Landin_Name_For_Record (S : Handle; Index : Positive)
     return String
   is
      Choice : constant Natural :=
        Find (S.Record_Entries, US.To_String (S.Records (Index).Identity));
      Display : constant String := C.Record_Display (S, Index);
   begin
      if Choice /= 0 then
         return Entry_Landin (S, Choice);
      end if;
      return T.Sanitize_Landin
        ((if Display /= "" then Display else "anonymous_record"));
   end Landin_Name_For_Record;

   function Landin_Name_For_Enum (S : Handle; Index : Positive)
     return String;

   function Landin_Name_For_Enum (S : Handle; Index : Positive)
     return String
   is
      Choice : constant Natural :=
        Find (S.Enum_Entries, US.To_String (S.Enums (Index).Identity));
      Display : constant String := C.Enum_Display (S, Index);
   begin
      if Choice /= 0 then
         return Entry_Landin (S, Choice);
      end if;
      if Display /= "" then
         return T.Sanitize_Landin (Display);
      end if;
      return T.Sanitize_Landin
        (C.Text (S, C.Enum_Constants (S, Index).First_Element, "name")
         & "_enum");
   end Landin_Name_For_Enum;

   function Landin_Name_For_Alias (S : Handle; Name : String) return String;

   function Landin_Name_For_Alias (S : Handle; Name : String) return String
   is
      Choice : Natural := Find (S.Alias_Entries, Name);
   begin
      if Choice = 0 then
         Choice := Find (S.Callback_Entries, Name);
      end if;
      return (if Choice /= 0 then Entry_Landin (S, Choice)
              else T.Sanitize_Landin (Name));
   end Landin_Name_For_Alias;

   function Address_Type
     (S : Handle; Id : Type_Id; Mutable : Boolean) return String;

   function Address_Type
     (S : Handle; Id : Type_Id; Mutable : Boolean) return String
   is
      Target : constant String := (if Mutable then "mut " else "");
   begin
      if Pointer_Only (S, Id) then
         return "ptr " & Target & Landin_Name_For_Record
           (S, C.Record_Index (S, Name (S, Resolve (S, Id))));
      end if;
      return "ptr " & Target & "u8";
   end Address_Type;

   function Native_Field_Possible (S : Handle; Id : Type_Id) return Boolean;

   function Native_Field_Possible (S : Handle; Id : Type_Id) return Boolean
   is
      Resolved : constant Type_Id := Resolve (S, Id);
   begin
      case Kind (S, Resolved) is
         when Builtin_Type | Pointer_Type | Callback_Type | Enum_Type =>
            return True;
         when Array_Type =>
            return Get (S, Resolved).Child /= No_Type
              and then Get (S, Resolved).Count > 0
              and then Native_Field_Possible (S, Get (S, Resolved).Child);
         when Record_Type =>
            declare
               Index : constant Positive :=
                 C.Record_Index (S, Name (S, Resolved));
            begin
               return C.Record_Complete (S, Index)
                 and then Record_Classification (S, Index) = Native_Layout;
            end;
         when others =>
            return False;
      end case;
   end Native_Field_Possible;

   function Packed_Field_Possible (S : Handle; Id : Type_Id) return Boolean is
     (if Resolved_Kind (S, Id) in Array_Type | Record_Type
      then Byte_Aligned (S, Id) else True);

   function Record_Classification (S : Handle; Index : Positive)
     return String
   is
      Identity : constant String := US.To_String (S.Records (Index).Identity);
      Choice : constant Natural := Find (S.Record_Entries, Identity);
      Display : constant String := Record_Display (S, Index);
   begin
      if S.Classifications.Contains (Identity) then
         return S.Classifications (Identity);
      end if;
      for Typedef_Name of S.Records (Index).Typedef_Names loop
         Ensure_Typedef_Unattributed
           (S, Typedef_Name,
            (if Choice /= 0 then Context (S, Choice)
             else "record dependency " & Display));
      end loop;
      declare
         Requested : constant String :=
           (if Choice /= 0
            then P.Text (S, Raw (S, Choice), "representation") else "auto");
         Reference_Policy : constant J.Value :=
           (if Choice /= 0 then P.Field (S, Raw (S, Choice), "fields")
            else J.No_Value);
         Policy_Names : constant String_Sets.Set :=
           Key_Set (S, Reference_Policy);
      begin
         if not C.Record_Complete (S, Index) then
            if Requested = "native" then
               Fail (S, "record " & Display & ": incomplete record cannot"
                     & " have native representation");
            end if;
            if not Policy_Names.Is_Empty then
               Fail (S, "record " & Display & ": incomplete record has no"
                     & " fields; policy is stale");
            end if;
            S.Classifications.Include (Identity, Incomplete);
            return Incomplete;
         end if;
         declare
            Attribute : constant String := Forbidden_Attribute (S, Index);
         begin
            if Attribute /= "" then
               Fail (S, "record " & Display & ": unsupported record attribute "
                     & Attribute);
            end if;
         end;
         declare
            Fields : constant Value_Vectors.Vector :=
              C.Record_Fields (S, Index);
            Has_Bitfield : constant Boolean :=
              (for some Field of Fields => C.Truthy (S, Field, "isBitfield"));
            Unnamed : constant Boolean :=
              (for some Field of Fields => C.Text (S, Field, "name") = "");
            Actual_Named : String_Sets.Set;
            Normalized : String_Sets.Set;
            Nullable_Field : Boolean := False;
            Native_Fields : Boolean := True;
            Flexible : J.Value := J.No_Value;
            Packed : constant Boolean := C.Record_Packed (S, Index);
            Union : constant Boolean := C.Record_Union (S, Index);
         begin
            if Fields.Is_Empty then
               Fail (S, "record " & Display & ": empty or zero-size record is"
                     & " unsupported");
            end if;
            for Field of Fields loop
               declare
                  Field_Name : constant String := C.Text (S, Field, "name");
               begin
                  if Field_Name /= "" then
                     Actual_Named.Include (Field_Name);
                     if Normalized.Contains (T.Sanitize_Landin (Field_Name))
                     then
                        Fail (S, "record " & Display & ": field names collide"
                              & " after Landin normalization");
                     end if;
                     Normalized.Include (T.Sanitize_Landin (Field_Name));
                  end if;
               end;
            end loop;
            for Key of Policy_Names loop
               if not Actual_Named.Contains (Key) then
                  Fail (S, "record " & Display & ": field " & T.Repr (Key)
                        & " is absent (stale policy)");
               end if;
            end loop;
            for Position in 1 .. Natural (Fields.Length) loop
               declare
                  Field : constant J.Value := Fields (Position);
                  Field_Name : constant String := C.Text (S, Field, "name");
                  Label : constant String :=
                    Field_Label (S, Field, Position);
               begin
                  if Field_Name = "" and then not C.Truthy (S, Field,
                    "isBitfield")
                  then
                     Fail (S, "record " & Display & " field"
                           & Positive'Image (Position)
                           & ": anonymous aggregate field is unsupported");
                  end if;
                  for Item of C.Inner (S, Field) loop
                     if T.Ends_With (C.Text (S, Item, "kind"), "Attr") then
                        Fail (S, "record " & Display & " field " & Label
                              & ": unsupported field attribute "
                              & C.Text (S, Item, "kind"));
                     end if;
                  end loop;
                  declare
                     Item : constant Type_Id := Type_Of (S, Field);
                     Field_Context : constant String :=
                       "record " & Display & " field " & Label;
                     Resolved_Field : constant Type_Id := Resolve (S, Item);
                  begin
                     if Kind (S, Resolved_Field) = Array_Type
                       and then Get (S, Resolved_Field).Count <= 0
                     then
                        if Union or else Position /= Natural (Fields.Length)
                          or else Position = 1
                        then
                           Fail (S, Field_Context & ": flexible or zero-size"
                                 & " array is unsupported except as a"
                                 & " struct's last field after another field"
                                 & " (D413)");
                        end if;
                        declare
                           Element : constant Type_Id :=
                             Get (S, Resolved_Field).Child;
                        begin
                           Ensure_Supported
                             (S, Element, Field_Context & " element");
                           declare
                              Resolved_Element : constant Type_Id :=
                                Resolve (S, Element);
                           begin
                              if Kind (S, Resolved_Element) = Array_Type
                                and then Get (S, Resolved_Element).Count <= 0
                              then
                                 Fail (S, Field_Context & ": flexible or"
                                       & " zero-size array is unsupported");
                              end if;
                           end;
                           Native_Fields := Native_Fields
                             and then Native_Field_Possible (S, Element);
                           Flexible := Field;
                        end;
                     else
                        Ensure_Supported (S, Item, Field_Context);
                        Native_Fields := Native_Fields
                          and then Native_Field_Possible (S, Item);
                        if Packed then
                           Native_Fields := Native_Fields
                             and then Packed_Field_Possible (S, Item);
                        end if;
                     end if;
                     if Get (S, Resolve (S, Item)).Const then
                        Fail (S, "record " & Display & " field " & Label
                              & ": const field unsupported");
                     end if;
                     if Contains_Reference (S, Item) then
                        if Field_Name = ""
                          or else not Policy_Names.Contains (Field_Name)
                        then
                           Fail (S, "record " & Display & " field " & Label
                                 & ": missing required pointer policy");
                        end if;
                        declare
                           Note : constant Annotation := P.Annotation_Of
                             (S, P.Field (S, Reference_Policy, Field_Name),
                              "record " & Display & " field "
                              & T.Repr (Field_Name));
                        begin
                           if not Note.From.Is_Empty then
                              Fail (S, "record " & Display & " field "
                                    & T.Repr (Field_Name)
                                    & ": from must be empty");
                           end if;
                           S.Annotations.Include
                             (Field_Key (Identity, Field_Name), Note);
                           Nullable_Field := Nullable_Field
                             or else Nullable (Note);
                        end;
                     elsif Field_Name /= ""
                       and then Policy_Names.Contains (Field_Name)
                     then
                        Fail (S, "record " & Display & " field "
                              & T.Repr (Field_Name)
                              & ": a non-reference field takes no policy;"
                              & " remove " & T.Repr (Field_Name)
                              & " from ""fields""");
                     end if;
                  end;
               end;
            end loop;
            declare
               Native_Possible : constant Boolean :=
                 not Union and then not Has_Bitfield and then not Unnamed
                 and then not Nullable_Field and then Native_Fields;
            begin
               if J.Is_Present (Flexible) then
                  if Requested = "opaque" or else not Native_Possible then
                     Fail (S, "record " & Display & ": a record with a"
                           & " flexible array member has only a native"
                           & " layout(c) form (D413), and needs no bitfield,"
                           & " unnamed or nullable field and a C element");
                  end if;
               end if;
               if Requested = "native" then
                  if not Native_Possible then
                     Fail (S, "record " & Display & ": selected native"
                           & " representation is incompatible with union,"
                           & " bitfield, unnamed, or nullable field"
                           & (if Packed then ", or with a packed record's"
                              & " field of alignment above one (D410)"
                              else ""));
                  end if;
                  S.Classifications.Include (Identity, Native_Layout);
                  return Native_Layout;
               end if;
               if Requested = "opaque" then
                  S.Classifications.Include (Identity, Opaque_Storage);
                  return Opaque_Storage;
               end if;
               S.Classifications.Include
                 (Identity,
                  (if Native_Possible then Native_Layout else Opaque_Storage));
               return S.Classifications (Identity);
            end;
         end;
      end;
   end Record_Classification;

   ---------------------------------------------------------------------
   --  Dependencies
   ---------------------------------------------------------------------

   procedure Need_Record (S : Handle; Identity : String);

   procedure Need_Record (S : Handle; Identity : String) is
   begin
      if not S.Needed_Records.Contains (Identity) then
         S.Needed_Records.Insert (Identity);
         S.Pending.Append
           (Dependency'(Is_Record => True, Is_Callback => False,
             Name => US.To_Unbounded_String (Identity)));
      end if;
   end Need_Record;

   procedure Need_Alias (S : Handle; Name : String);

   procedure Need_Alias (S : Handle; Name : String) is
   begin
      if not S.Needed_Aliases.Contains (Name) then
         S.Needed_Aliases.Insert (Name);
         S.Pending.Append
           (Dependency'(Is_Record => False, Is_Callback => False,
             Name => US.To_Unbounded_String (Name)));
      end if;
   end Need_Alias;

   procedure Need_Callback (S : Handle; Name : String);

   procedure Need_Callback (S : Handle; Name : String) is
   begin
      if not S.Needed_Callbacks.Contains (Name) then
         S.Needed_Callbacks.Insert (Name);
         S.Pending.Append
           (Dependency'(Is_Record => False, Is_Callback => True,
             Name => US.To_Unbounded_String (Name)));
      end if;
   end Need_Callback;

   procedure Register_Type
     (S : Handle; Id : Type_Id; By_Value : Boolean := True);

   procedure Register_Type
     (S : Handle; Id : Type_Id; By_Value : Boolean := True) is
   begin
      if Kind (S, Id) = Alias_Type then
         declare
            Alias_Name : constant String := Name (S, Id);
         begin
            if S.Records_By_Typedef.Contains (Alias_Name) then
               if By_Value then
                  Need_Record
                    (S, US.To_String
                          (S.Records (S.Records_By_Typedef (Alias_Name))
                           .Identity));
               end if;
            elsif S.Enums_By_Typedef.Contains (Alias_Name) then
               S.Needed_Enums.Include
                 (US.To_String
                    (S.Enums (S.Enums_By_Typedef (Alias_Name)).Identity));
            elsif Resolved_Kind (S, Id) = Callback_Type then
               Need_Callback (S, Alias_Name);
            else
               Need_Alias (S, Alias_Name);
               Register_Type (S, Get (S, Id).Child, By_Value);
            end if;
         end;
         return;
      end if;
      declare
         Resolved : constant Type_Id := Resolve (S, Id);
         Item : constant C_Type := Get (S, Resolved);
      begin
         case Item.Kind is
            when Record_Type =>
               if By_Value then
                  Need_Record (S, US.To_String (Item.Name));
               end if;
            when Enum_Type =>
               S.Needed_Enums.Include (US.To_String (Item.Name));
            when Array_Type =>
               if Item.Child /= No_Type then
                  Register_Type (S, Item.Child, By_Value);
               end if;
            when Pointer_Type =>
               if Item.Child /= No_Type
                 and then Resolved_Kind (S, Item.Child)
                          not in Record_Type | Unsupported_Type | Builtin_Type
               then
                  Register_Type (S, Item.Child, By_Value => False);
               end if;
            when Callback_Type =>
               Register_Type (S, Item.Result);
               for Parameter of Item.Parameters loop
                  Register_Type (S, Parameter);
               end loop;
            when others =>
               null;
         end case;
      end;
   end Register_Type;

   procedure Select_Declarations (S : Handle) is
      Callable_Names : String_Sets.Set;
   begin
      --  Incoming handlers are policy-supplied symbols whose declarations
      --  are generated here: no adapter symbol or local may take one.
      for Each of S.Entries loop
         if Each.Kind = Incoming_Entry then
            S.C_Symbols.Include (P.Text (S, Each.Raw, "handler"));
         end if;
      end loop;
      for Choice in 1 .. S.Entries.Last_Index loop
         declare
            Item : constant Policy_Entry := S.Entries (Choice);
            Where : constant String := Context (S, Choice);
            Selected : constant String := US.To_String (Item.Name);
         begin
            Claim_Landin (S, US.To_String (Item.Landin_Name), Where);
            case Item.Kind is
               when Record_Entry =>
                  declare
                     Index : constant Natural := C.Record_Of (S, Selected);
                  begin
                     if Index = 0 then
                        Fail (S, Where & ": selected record was not found in"
                              & " Clang AST (stale policy)");
                     end if;
                     if S.Typedefs.Contains (Selected) then
                        Ensure_Typedef_Unattributed (S, Selected, Where);
                     end if;
                     declare
                        Identity : constant String :=
                          US.To_String (S.Records (Index).Identity);
                     begin
                        if S.Record_Entries.Contains (Identity) then
                           Fail (S, Where & ": record aliases select the same"
                                 & " C declaration twice");
                        end if;
                        S.Record_Entries.Insert (Identity, Choice);
                        Need_Record (S, Identity);
                     end;
                  end;
               when Enum_Entry =>
                  declare
                     Index : constant Natural := C.Enum_Of (S, Selected);
                  begin
                     if Index = 0 then
                        Fail (S, Where & ": selected enum was not found in"
                              & " Clang AST (stale policy)");
                     end if;
                     if S.Typedefs.Contains (Selected) then
                        Ensure_Typedef_Unattributed (S, Selected, Where);
                     end if;
                     declare
                        Identity : constant String :=
                          US.To_String (S.Enums (Index).Identity);
                     begin
                        if S.Enum_Entries.Contains (Identity) then
                           Fail (S, Where & ": enum aliases select the same C"
                                 & " declaration twice");
                        end if;
                        S.Enum_Entries.Insert (Identity, Choice);
                        S.Needed_Enums.Include (Identity);
                     end;
                  end;
               when Callback_Entry | Alias_Entry =>
                  if not S.Typedefs.Contains (Selected) then
                     Fail (S, Where & ": selected typedef was not found in"
                           & " Clang AST (stale policy)");
                  end if;
                  Ensure_Typedef_Unattributed (S, Selected, Where);
                  declare
                     Parsed : constant Type_Id := C.Alias (S, Selected);
                     Resolved : constant Type_Kind := Resolved_Kind (S,
                       Parsed);
                  begin
                     if Item.Kind = Callback_Entry then
                        Ensure_Supported (S, Parsed, Where);
                        if Resolved /= Callback_Type then
                           Fail (S, Where & ": selected typedef is not a"
                                 & " function pointer");
                        end if;
                        S.Callback_Entries.Include (Selected, Choice);
                        Need_Callback (S, Selected);
                     else
                        if Resolved in Callback_Type | Record_Type | Enum_Type
                        then
                           Fail (S, Where & ": aggregate, enum, or"
                                 & " function-pointer typedef must use its"
                                 & " matching policy kind");
                        end if;
                        S.Alias_Entries.Include (Selected, Choice);
                        Need_Alias (S, Selected);
                     end if;
                  end;
               when Function_Entry | Incoming_Entry =>
                  if Callable_Names.Contains (Selected) then
                     Fail (S, Where & ": C function is selected more than once"
                           & " across callable policy kinds");
                  end if;
                  Callable_Names.Include (Selected);
                  declare
                     Node : constant J.Value := C.Function_Node (S, Selected);
                  begin
                     if not J.Is_Present (Node) then
                        Fail (S, Where & ": selected function was not found in"
                              & " Clang AST (stale policy)");
                     end if;
                     if Item.Kind = Function_Entry then
                        S.Function_Entries.Append
                          (Selection'(Choice => Choice, Node => Node));
                     else
                        S.Incoming_Entries.Append
                          (Selection'(Choice => Choice, Node => Node));
                     end if;
                  end;
               when Variable_Entry =>
                  declare
                     Node : constant J.Value := C.Variable_Node (S, Selected);
                  begin
                     if not J.Is_Present (Node) then
                        Fail (S, Where & ": selected variable was not found in"
                              & " Clang AST (stale policy)");
                     end if;
                     S.Variable_Entries.Append
                       (Selection'(Choice => Choice, Node => Node));
                  end;
            end case;
         end;
      end loop;
   end Select_Declarations;

   procedure Collect_Dependencies (S : Handle) is
   begin
      if not S.Roots_Collected then
         for Rooted of Selection_Vectors."&"
                         (S.Function_Entries, S.Incoming_Entries)
         loop
            declare
               Params : Value_Vectors.Vector;
               Result : Type_Id;
            begin
               Validate_Function_Shape
                 (S, Rooted.Choice, Rooted.Node, Params, Result);
               for Parameter of Params loop
                  Register_Type (S, Type_Of (S, Parameter));
               end loop;
               Register_Type (S, Result);
            end;
         end loop;
         for Rooted of S.Variable_Entries loop
            declare
               Item : constant Type_Id := Type_Of (S, Rooted.Node);
            begin
               Ensure_Supported (S, Item, Context (S, Rooted.Choice));
               Register_Type (S, Item);
            end;
         end loop;
         S.Roots_Collected := True;
      end if;
      while S.Next_Pending <= S.Pending.Last_Index loop
         declare
            Next : constant Dependency := S.Pending (S.Next_Pending);
            Named : constant String := US.To_String (Next.Name);
         begin
            S.Next_Pending := S.Next_Pending + 1;
            if Next.Is_Record then
               declare
                  Index : constant Positive := C.Record_Index (S, Named);
               begin
                  if C.Record_Complete (S, Index) then
                     declare
                        Ignored : constant String :=
                          Record_Classification (S, Index);
                        pragma Unreferenced (Ignored);
                     begin
                        for Field of C.Record_Fields (S, Index) loop
                           Register_Type (S, Type_Of (S, Field));
                        end loop;
                     end;
                  end if;
               end;
            else
               Register_Type (S, Get (S, C.Alias (S, Named)).Child);
            end if;
         end;
      end loop;
   end Collect_Dependencies;

   --  Sort Keys' positions by Keys, then by Ties: Python's sorted with a
   --  key, made deterministic where Python's set order would decide.
   function Sorted_Order
     (Keys, Ties : String_Vectors.Vector) return String_Vectors.Vector;

   function Sorted_Order
     (Keys, Ties : String_Vectors.Vector) return String_Vectors.Vector
   is
      Count : constant Natural := Natural (Keys.Length);
      Order : array (1 .. Count) of Positive;
      Result : String_Vectors.Vector;

      function Before (Left, Right : Positive) return Boolean is
        (Keys (Left) < Keys (Right)
         or else (Keys (Left) = Keys (Right)
                  and then (Ties (Left) < Ties (Right)
                            or else (Ties (Left) = Ties (Right)
                                     and then Left < Right))));
   begin
      for Position in Order'Range loop
         Order (Position) := Position;
      end loop;
      for Position in 2 .. Count loop
         declare
            Moving : constant Positive := Order (Position);
            Place : Natural := Position - 1;
         begin
            while Place >= 1 and then Before (Moving, Order (Place)) loop
               Order (Place + 1) := Order (Place);
               Place := Place - 1;
            end loop;
            Order (Place + 1) := Moving;
         end;
      end loop;
      for Position of Order loop
         Result.Append (Ties (Position));
      end loop;
      return Result;
   end Sorted_Order;

   function Snapshot (Set : String_Sets.Set) return String_Vectors.Vector;

   function Snapshot (Set : String_Sets.Set) return String_Vectors.Vector is
      Result : String_Vectors.Vector;
   begin
      for Item of Set loop
         Result.Append (Item);
      end loop;
      return Result;
   end Snapshot;

   function Probe_Order (S : Handle) return String_Vectors.Vector is
      Identities : constant String_Vectors.Vector :=
        Snapshot (S.Needed_Enums);
      Names : String_Vectors.Vector;
   begin
      for Identity of Identities loop
         Names.Append
           (Landin_Name_For_Enum (S, C.Enum_Index (S, Identity)));
      end loop;
      return Sorted_Order (Names, Identities);
   end Probe_Order;

   ---------------------------------------------------------------------
   --  Layout
   ---------------------------------------------------------------------

   type Field_Offset is record
      Name : US.Unbounded_String;
      Offset : Natural;
   end record;

   package Offset_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Field_Offset);

   procedure Layout_Of
     (S : Handle; Id : Type_Id; Stack : String_Sets.Set;
      Size, Alignment : out Natural);

   procedure Record_Layout
     (S : Handle; Index : Positive; Stack : String_Sets.Set;
      Size, Alignment : out Natural; Offsets : out Offset_Vectors.Vector);

   function Align_Up (Value, Alignment : Natural) return Natural is
     ((Value + Alignment - 1) / Alignment * Alignment);

   procedure Layout_Of
     (S : Handle; Id : Type_Id; Stack : String_Sets.Set;
      Size, Alignment : out Natural)
   is
      Resolved : constant Type_Id := Resolve (S, Id);
      Item : constant C_Type := Get (S, Resolved);
   begin
      case Item.Kind is
         when Builtin_Type =>
            Size := Builtin_Size (S, US.To_String (Item.Name));
            if Size = 0 then
               Fail (S, "unsupported layout for "
                     & US.To_String (Item.Spelling));
            end if;
            Alignment := Size;
         when Pointer_Type | Callback_Type =>
            Size := Word_Size (S.Chosen);
            Alignment := Word_Size (S.Chosen);
         when Enum_Type =>
            Layout_Of (S, Enum_Underlying (S, Enum_For (S, Resolved)), Stack,
                       Size, Alignment);
         when Array_Type =>
            if Item.Count <= 0 then
               Fail (S, "unsupported array extent in "
                     & US.To_String (Item.Spelling));
            end if;
            Layout_Of (S, Item.Child, Stack, Size, Alignment);
            Size := Size * Natural (Item.Count);
         when Record_Type =>
            if Stack.Contains (US.To_String (Item.Name)) then
               Fail (S, "recursive by-value record layout");
            end if;
            declare
               Index : constant Positive :=
                 C.Record_Index (S, US.To_String (Item.Name));
               Offsets : Offset_Vectors.Vector;
            begin
               if Record_Classification (S, Index) /= Native_Layout then
                  Fail (S, "record " & Record_Display (S, Index)
                        & " has no native Landin layout");
               end if;
               Record_Layout (S, Index, Stack, Size, Alignment, Offsets);
            end;
         when others =>
            Fail (S, "unsupported layout type "
                  & US.To_String (Item.Spelling));
      end case;
   end Layout_Of;

   --  D410: a packed record places every field at alignment one.  D413: a
   --  flexible array member has size zero and its element's alignment.
   procedure Record_Layout
     (S : Handle; Index : Positive; Stack : String_Sets.Set;
      Size, Alignment : out Natural; Offsets : out Offset_Vectors.Vector)
   is
      Flexible : constant J.Value := Flexible_Field (S, Index);
      Nested : String_Sets.Set := Stack;
      Packed : constant Boolean := C.Record_Packed (S, Index);
   begin
      Nested.Include (US.To_String (S.Records (Index).Identity));
      Size := 0;
      Alignment := 1;
      Offsets.Clear;
      for Field of C.Record_Fields (S, Index) loop
         declare
            Item : constant Type_Id := Type_Of (S, Field);
            Field_Size, Field_Alignment : Natural;
         begin
            if Field = Flexible then
               Layout_Of (S, Get (S, Resolve (S, Item)).Child, Nested,
                          Field_Size, Field_Alignment);
               Field_Size := 0;
            else
               Layout_Of (S, Item, Nested, Field_Size, Field_Alignment);
            end if;
            if Packed then
               Field_Alignment := 1;
            end if;
            Size := Align_Up (Size, Field_Alignment);
            Offsets.Append
              (Field_Offset'(Name => US.To_Unbounded_String (C.Text (S, Field,
                "name")),
                Offset => Size));
            Size := Size + Field_Size;
            Alignment := Natural'Max (Alignment, Field_Alignment);
         end;
      end loop;
      Size := Align_Up (Size, Alignment);
   end Record_Layout;

   function Layout_Size (S : Handle; Id : Type_Id) return Natural is
      Size, Alignment : Natural;
   begin
      Layout_Of (S, Id, String_Sets.Empty_Set, Size, Alignment);
      return Size;
   end Layout_Size;

   function Layout_Alignment (S : Handle; Id : Type_Id) return Natural is
      Size, Alignment : Natural;
   begin
      Layout_Of (S, Id, String_Sets.Empty_Set, Size, Alignment);
      return Alignment;
   end Layout_Alignment;

   ---------------------------------------------------------------------
   --  C spellings
   ---------------------------------------------------------------------

   function Qualifier (Const : Boolean) return String is
     (if Const then "const " else "");

   function C_Type_Text (S : Handle; Id : Type_Id) return String is
   begin
      if Kind (S, Id) = Alias_Type then
         return Qualifier (Get (S, Id).Const) & Name (S, Id);
      end if;
      declare
         Resolved : constant Type_Id := Resolve (S, Id);
         Item : constant C_Type := Get (S, Resolved);
      begin
         case Item.Kind is
            when Builtin_Type =>
               return Qualifier (Item.Const) & US.To_String (Item.Name);
            when Record_Type =>
               return Qualifier (Item.Const) & C.Record_C_Name
                 (S, C.Record_Index (S, US.To_String (Item.Name)));
            when Enum_Type =>
               return Qualifier (Item.Const) & C.Enum_C_Name
                 (S, C.Enum_Index (S, US.To_String (Item.Name)));
            when Pointer_Type | Array_Type | Callback_Type | Function_Type =>
               return T.Strip (C_Declarator (S, Resolved, ""));
            when others =>
               Fail (S, "cannot render C type "
                     & US.To_String (Item.Spelling));
         end case;
      end;
   end C_Type_Text;

   function C_Declarator
     (S : Handle; Id : Type_Id; Declared : String) return String is
   begin
      if Kind (S, Id) = Alias_Type then
         return Qualifier (Get (S, Id).Const) & Name (S, Id) & " "
           & Declared;
      end if;
      declare
         Resolved : constant Type_Id := Resolve (S, Id);
         Item : constant C_Type := Get (S, Resolved);
      begin
         case Item.Kind is
            when Callback_Type | Function_Type =>
               declare
                  Parts : String_Vectors.Vector;
                  Params : US.Unbounded_String;
                  Named : US.Unbounded_String :=
                    US.To_Unbounded_String (Declared);
               begin
                  for Parameter of Item.Parameters loop
                     Parts.Append (C_Type_Text (S, Parameter));
                  end loop;
                  Params := US.To_Unbounded_String (T.Join (Parts, ", "));
                  if US.Length (Params) = 0 then
                     Params := US.To_Unbounded_String ("void");
                  end if;
                  if Item.Variadic then
                     if US.To_String (Params) /= "void" then
                        US.Append (Params, ", ...");
                     else
                        Params := US.To_Unbounded_String ("...");
                     end if;
                  end if;
                  if Item.Kind = Callback_Type then
                     Named := US.To_Unbounded_String
                       ("(*" & (if Item.Const then " const " else "")
                        & US.To_String (Named) & ")");
                  end if;
                  return C_Declarator
                    (S, Item.Result,
                     US.To_String (Named) & "(" & US.To_String (Params)
                     & ")");
               end;
            when Array_Type =>
               return C_Declarator
                 (S, Item.Child,
                  Declared & "["
                  & (if Item.Count < 0 then "" else Image (Item.Count))
                  & "]");
            when Pointer_Type =>
               declare
                  Named : constant String :=
                    "*" & (if Item.Const then " const " else "") & Declared;
               begin
                  return C_Declarator
                    (S, Item.Child,
                     (if Resolved_Kind (S, Item.Child)
                           in Array_Type | Function_Type
                      then "(" & Named & ")" else Named));
               end;
            when others =>
               return C_Type_Text (S, Id) & " " & Declared;
         end case;
      end;
   end C_Declarator;

   function C_Prototype_Parameter
     (S : Handle; Id : Type_Id; Declared : String) return String is
     (T.Strip (C_Declarator
                 (S, Id, (if S.Typedefs.Contains (Declared) then ""
                          else Declared))));

   function Pointer_To (S : Handle; Id : Type_Id) return Type_Id is
     (C.Make (S, (Kind => Pointer_Type,
                  Spelling => US.To_Unbounded_String
                    (C_Type_Text (S, Id) & " *"),
                  Child => Id, others => <>)));

   ---------------------------------------------------------------------
   --  Landin spellings
   ---------------------------------------------------------------------

   function Optional_For
     (S : Handle; Site : String; Member_Type : String) return String;

   function Optional_For
     (S : Handle; Site : String; Member_Type : String) return String
   is
   begin
      if S.Optionals.Contains (Site) then
         if US.To_String (S.Optionals (Site).Member_Type) /= Member_Type then
            Fail (S, "optional type collision at " & Site);
         end if;
         return US.To_String (S.Optionals (Site).Name);
      end if;
      declare
         Base : constant String :=
           T.Sanitize_Landin (US.To_String (S.Namespace) & "_" & Site);
         Absent : constant String := Claim_Generated_Landin
           (S, Base & "_absent", "generated optional " & Site);
         Named : constant String := Claim_Generated_Landin
           (S, Base & "_optional", "generated optional " & Site);
      begin
         S.Optionals.Insert
           (Site,
            (Name => US.To_Unbounded_String (Named),
             Absent => US.To_Unbounded_String (Absent),
             Member_Type => US.To_Unbounded_String (Member_Type)));
         return Named;
      end;
   end Optional_For;

   function Landin_Type
     (S : Handle; Id : Type_Id; Note : Annotation := No_Annotation;
      Site : String := "value"; Pointer_As_Opaque : Boolean := False)
      return String
   is
   begin
      if Kind (S, Id) = Alias_Type then
         declare
            Resolved : constant Type_Id := Resolve (S, Id);
            Alias_Name : constant String := Name (S, Id);
            Base : US.Unbounded_String;
         begin
            case Kind (S, Resolved) is
               when Record_Type =>
                  if Pointer_As_Opaque then
                     return "u8";
                  end if;
                  return Landin_Name_For_Record
                    (S, C.Record_Index (S, Name (S, Resolved)));
               when Enum_Type =>
                  return Landin_Name_For_Enum
                    (S, C.Enum_Index (S, Name (S, Resolved)));
               when Callback_Type =>
                  S.Needed_Callbacks.Include (Alias_Name);
                  Base := US.To_Unbounded_String
                    (Landin_Name_For_Alias (S, Alias_Name));
               when others =>
                  if S.Needed_Aliases.Contains (Alias_Name)
                    or else S.Alias_Entries.Contains (Alias_Name)
                  then
                     Base := US.To_Unbounded_String
                       (Landin_Name_For_Alias (S, Alias_Name));
                  else
                     Base := US.To_Unbounded_String
                       (Landin_Type (S, Get (S, Id).Child, No_Annotation,
                                     Site, Pointer_As_Opaque));
                  end if;
            end case;
            if Nullable (Note) and then Kind (S, Resolved) = Pointer_Type then
               return Optional_For (S, Site, US.To_String (Base));
            end if;
            return US.To_String (Base);
         end;
      end if;
      declare
         Resolved : constant Type_Id := Resolve (S, Id);
         Item : constant C_Type := Get (S, Resolved);
      begin
         case Item.Kind is
            when Builtin_Type =>
               if US.To_String (Item.Name) = "void" then
                  Fail (S, "void has no Landin value type");
               end if;
               return Builtin_Landin (US.To_String (Item.Name));
            when Enum_Type =>
               S.Needed_Enums.Include (US.To_String (Item.Name));
               return Landin_Name_For_Enum
                 (S, C.Enum_Index (S, US.To_String (Item.Name)));
            when Record_Type =>
               if Pointer_As_Opaque then
                  return "u8";
               end if;
               S.Needed_Records.Include (US.To_String (Item.Name));
               return Landin_Name_For_Record
                 (S, C.Record_Index (S, US.To_String (Item.Name)));
            when Array_Type =>
               declare
                  Element : constant String :=
                    Landin_Type (S, Item.Child, Site => Site);
               begin
                  return "["
                    & Image (Long_Long_Integer'Max (Item.Count, 0)) & "]"
                    & Element;
               end;
            when Pointer_Type =>
               declare
                  Pointee : constant Type_Id := Resolve (S, Item.Child);
                  Inner : US.Unbounded_String;
               begin
                  if Kind (S, Pointee) = Record_Type
                    and then S.Record_Entries.Contains (Name (S, Pointee))
                    and then Pointer_Only (S, Pointee)
                  then
                     --  D414: C reaches a selected packed or flexible-member
                     --  record only through a pointer, so the pointer
                     --  carries its type.
                     Inner := US.To_Unbounded_String
                       (Landin_Name_For_Record
                          (S, C.Record_Index (S, Name (S, Pointee))));
                  elsif Kind (S, Pointee) in Record_Type | Unsupported_Type
                    or else Is_Void (S, Pointee)
                  then
                     Inner := US.To_Unbounded_String ("u8");
                  else
                     Inner := US.To_Unbounded_String
                       (Landin_Type (S, Item.Child, Site => Site,
                                     Pointer_As_Opaque => True));
                  end if;
                  declare
                     Base : constant String :=
                       "ptr " & (if Get (S, Pointee).Const then "" else "mut ")
                       & US.To_String (Inner);
                  begin
                     if Nullable (Note) then
                        return Optional_For (S, Site, Base);
                     end if;
                     return Base;
                  end;
               end;
            when Callback_Type =>
               declare
                  Params : String_Vectors.Vector;
               begin
                  for Position in 1 .. Natural (Item.Parameters.Length) loop
                     declare
                        Rendered : constant String :=
                          Landin_Type (S, Item.Parameters (Position),
                                       Site => Site & "_argument");
                     begin
                        Params.Append
                          ("argument_" & Number (Position) & ": " & Rendered);
                     end;
                  end loop;
                  if Item.Variadic then
                     Params.Append ("...");
                  end if;
                  declare
                     Result : constant String :=
                       Landin_Return
                         (S, Item.Result, No_Annotation, Site & "_result");
                  begin
                     declare
                        Allocated : constant Landin_Signature :=
                          Signature (Params, Result);
                     begin
                        return "extern(c) ("
                          & T.Join (Allocated.Parameters, ", ") & ") -> "
                          & US.To_String (Allocated.Result);
                     end;
                  end;
               end;
            when others =>
               Fail (S, "cannot render Landin type "
                     & US.To_String (Item.Spelling));
         end case;
      end;
   end Landin_Type;

   function Landin_Return
     (S : Handle; Id : Type_Id; Note : Annotation; Site : String;
      Result_Name : String := "result") return String
   is
   begin
      if Is_Void (S, Resolve (S, Id)) then
         return "none";
      end if;
      declare
         Rendered : constant String := Landin_Type (S, Id, Note, Site);
         Sources : String_Vectors.Vector;
      begin
         if Note.Present and then not Note.From.Is_Empty then
            for Source of Note.From loop
               Sources.Append (T.Sanitize_Landin (Source));
            end loop;
         end if;
         return "(" & T.Sanitize_Landin (Result_Name) & ": " & Rendered
           & (if Sources.Is_Empty then ""
              else " from " & T.Join (Sources, ", ")) & ")";
      end;
   end Landin_Return;

   function Retains_References
     (S : Handle; Id : Type_Id;
      Visiting : String_Sets.Set := String_Sets.Empty_Set) return Boolean;

   function Retains_References
     (S : Handle; Id : Type_Id;
      Visiting : String_Sets.Set := String_Sets.Empty_Set) return Boolean
   is
      Resolved : constant Type_Id := Resolve (S, Id);
   begin
      if Kind (S, Resolved) = Array_Type
        and then Get (S, Resolved).Child /= No_Type
      then
         return Retains_References (S, Get (S, Resolved).Child, Visiting);
      end if;
      if Kind (S, Resolved) /= Record_Type
        or else Visiting.Contains (Name (S, Resolved))
      then
         return False;
      end if;
      declare
         Index : constant Positive := C.Record_Index (S, Name (S, Resolved));
         Nested : String_Sets.Set := Visiting;
         Identity : constant String :=
           US.To_String (S.Records (Index).Identity);
      begin
         if C.Record_Complete (S, Index) then
            declare
               Ignored : constant String := Record_Classification (S, Index);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         end if;
         Nested.Include (Name (S, Resolved));
         for Field of C.Record_Fields (S, Index) loop
            declare
               Field_Type : constant Type_Id := Type_Of (S, Field);
               Field_Name : constant String := C.Text (S, Field, "name");
               Note : constant Annotation :=
                 (if Field_Name /= ""
                  then Lookup (S.Annotations, Field_Key (Identity, Field_Name))
                  else No_Annotation);
            begin
               if Retaining (Note) then
                  return True;
               end if;
               if Retains_References (S, Field_Type, Nested) then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end;
   end Retains_References;

   function Escaping_Prefix
     (S : Handle; Id : Type_Id; Note : Annotation;
      Output_Store : Boolean := False) return String is
     (if Output_Store or else Retaining (Note)
         or else Retains_References (S, Id)
      then "escaping " else "");

   function Landin_Opaque_Parameter
     (S : Handle; Id : Type_Id; Parameter : String;
      Note : Annotation := No_Annotation; Output_Store : Boolean := False)
      return String;

   function Landin_Opaque_Parameter
     (S : Handle; Id : Type_Id; Parameter : String;
      Note : Annotation := No_Annotation; Output_Store : Boolean := False)
      return String
   is
      Escaping : constant String :=
        Escaping_Prefix (S, Id, Note, Output_Store);
   begin
      return Escaping & T.Sanitize_Landin (Parameter) & ": "
        & Address_Type (S, Id, Mutable => False);
   end Landin_Opaque_Parameter;

   function Landin_Parameter
     (S : Handle; Id : Type_Id; C_Name : String; Note : Annotation;
      Site : String; Output_Store : Boolean := False) return String;

   function Landin_Parameter
     (S : Handle; Id : Type_Id; C_Name : String; Note : Annotation;
      Site : String; Output_Store : Boolean := False) return String
   is
      Clean : constant String := T.Sanitize_Landin (C_Name);
      Escaping : constant String :=
        Escaping_Prefix (S, Id, Note, Output_Store);
      Rendered : constant String := Landin_Type (S, Id, Note, Site);
   begin
      return Escaping & Clean & ": " & Rendered;
   end Landin_Parameter;

   --  Only generator-owned stores justify this check.  A call-only promise
   --  about an unknown foreign body remains policy, not an inferred fact.
   procedure Require_Storable_Policy
     (S : Handle; Id : Type_Id; Note : Annotation; Where : String);

   procedure Require_Storable_Policy
     (S : Handle; Id : Type_Id; Note : Annotation; Where : String) is
   begin
      if Contains_Reference (S, Id)
        and then (not Note.Present
                  or else US.To_String (Note.Retention) = "call")
      then
         Fail (S, Where & ": retention 'call' contradicts generated retaining"
               & " store; use an explicit stored, returned, or static policy");
      end if;
   end Require_Storable_Policy;

   --  An output parameter cannot have a result-from clause, so local
   --  origins are conservatively prohibited at the source of the known
   --  shallow output copy.
   function Opaque_Get_Source (S : Handle; Id : Type_Id) return String is
     ((if Contains_Reference (S, Id) then "escaping " else "")
      & "object: ptr u8");

   function Field_Return (S : Handle; Id : Type_Id; Rendered : String)
     return String is
     ("(value: " & Rendered
      & (if Contains_Reference (S, Id) then " from object" else "") & ")");

   ---------------------------------------------------------------------
   --  Metadata pieces
   ---------------------------------------------------------------------

   function Note_Meta (S : Handle; Note : Annotation) return Meta_Id;

   function Note_Meta (S : Handle; Note : Annotation) return Meta_Id is
   begin
      if not Note.Present then
         return T.Null_Meta (S);
      end if;
      declare
         Object : constant Meta_Id := T.Object_Meta (S);
      begin
         T.Put (S, Object, "ownership",
                T.String_Meta (S, US.To_String (Note.Ownership)));
         T.Put (S, Object, "nullability",
                T.String_Meta (S, US.To_String (Note.Nullability)));
         T.Put (S, Object, "from", T.Strings_Meta (S, Note.From));
         T.Put (S, Object, "retention",
                T.String_Meta (S, US.To_String (Note.Retention)));
         return Object;
      end;
   end Note_Meta;

   procedure Put_Text
     (S : Handle; Object : Meta_Id; Key : String; Text : String);

   procedure Put_Text
     (S : Handle; Object : Meta_Id; Key : String; Text : String) is
   begin
      T.Put (S, Object, Key, T.String_Meta (S, Text));
   end Put_Text;

   procedure Put_Flag
     (S : Handle; Object : Meta_Id; Key : String; Flag : Boolean);

   procedure Put_Flag
     (S : Handle; Object : Meta_Id; Key : String; Flag : Boolean) is
   begin
      T.Put (S, Object, Key, T.Boolean_Meta (S, Flag));
   end Put_Flag;

   procedure Put_Number
     (S : Handle; Object : Meta_Id; Key : String; Value : Natural);

   procedure Put_Number
     (S : Handle; Object : Meta_Id; Key : String; Value : Natural) is
   begin
      T.Put (S, Object, Key, T.Integer_Meta (S, Long_Long_Integer (Value)));
   end Put_Number;

   function Type_Metadata
     (S : Handle; Id : Type_Id; Note : Annotation; Site : String)
      return Meta_Id;

   function Type_Metadata
     (S : Handle; Id : Type_Id; Note : Annotation; Site : String)
      return Meta_Id
   is
      Object : constant Meta_Id := T.Object_Meta (S);
      Resolved : constant Type_Id := Resolve (S, Id);
   begin
      Put_Text (S, Object, "c_type", C_Type_Text (S, Id));
      if Is_Void (S, Resolved) then
         T.Put (S, Object, "landin_type", T.Null_Meta (S));
      else
         Put_Text (S, Object, "landin_type",
                   Landin_Type (S, Id, Note, Site));
      end if;
      T.Put (S, Object, "policy", Note_Meta (S, Note));
      return Object;
   end Type_Metadata;

   function Function_Parameter_Metadata
     (S : Handle; Params : Value_Vectors.Vector; Notes : Annotation_Maps.Map;
      Site_Prefix : String;
      Names : Text_Maps.Map := Text_Maps.Empty_Map) return Meta_Id;

   function Function_Parameter_Metadata
     (S : Handle; Params : Value_Vectors.Vector; Notes : Annotation_Maps.Map;
      Site_Prefix : String;
      Names : Text_Maps.Map := Text_Maps.Empty_Map) return Meta_Id
   is
      List : constant Meta_Id := T.List_Meta (S);
   begin
      for Index in 1 .. Natural (Params.Length) loop
         declare
            C_Name : constant String :=
              Parameter_Name (S, Params (Index), Index);
            Item : constant Type_Id := Type_Of (S, Params (Index));
            Object : constant Meta_Id := T.Object_Meta (S);
         begin
            Put_Text (S, Object, "c_name", C_Name);
            Put_Text
              (S, Object, "landin_name",
               (if Names.Contains (T.Sanitize_Landin (C_Name))
                then Names (T.Sanitize_Landin (C_Name))
                else T.Sanitize_Landin (C_Name)));
            Put_Text (S, Object, "c_type", C_Type_Text (S, Item));
            Put_Text (S, Object, "landin_type",
                      Landin_Type (S, Item, Lookup (Notes, C_Name),
                                   Site_Prefix & "_"
                                   & T.Sanitize_Landin (C_Name)));
            T.Put (S, Object, "policy", Note_Meta (S, Lookup (Notes, C_Name)));
            T.Append (S, List, Object);
         end;
      end loop;
      return List;
   end Function_Parameter_Metadata;

   function Symbols_Meta
     (S : Handle; Keys, Values : String_Vectors.Vector) return Meta_Id;

   function Symbols_Meta
     (S : Handle; Keys, Values : String_Vectors.Vector) return Meta_Id
   is
      Object : constant Meta_Id := T.Object_Meta (S);
   begin
      for Position in 1 .. Natural (Keys.Length) loop
         if Values (Position) = "" then
            T.Put (S, Object, Keys (Position), T.Null_Meta (S));
         else
            Put_Text (S, Object, Keys (Position), Values (Position));
         end if;
      end loop;
      return Object;
   end Symbols_Meta;

   ---------------------------------------------------------------------
   --  Generated C and Landin declarations
   ---------------------------------------------------------------------

   procedure Add_C_Function
     (S : Handle; Result, Named : String;
      Parameters, Body_Lines : String_Vectors.Vector);

   procedure Add_C_Function
     (S : Handle; Result, Named : String;
      Parameters, Body_Lines : String_Vectors.Vector) is
   begin
      S.C_Functions.Append
        (C_Function'(Result => US.To_Unbounded_String (Result),
          Name => US.To_Unbounded_String (Named),
          Parameters => Parameters, Body_Lines => Body_Lines));
   end Add_C_Function;

   function Signature
     (Parameters : String_Vectors.Vector; Result : String)
      return Landin_Signature
   is
      Used : String_Sets.Set;
      Answer : Landin_Signature;

      function Identifier (Value : Character) return Boolean is
        (Value in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_');

      function Name_Start (Text : String; Colon : Positive) return Positive;

      function Name_Start (Text : String; Colon : Positive) return Positive is
         First : Positive := Colon;
      begin
         while First > Text'First and then Identifier (Text (First - 1)) loop
            First := First - 1;
         end loop;
         return First;
      end Name_Start;

      procedure Reserve_Types (Text : String);

      procedure Reserve_Types (Text : String) is
         Index : Natural := Text'First;
         Depth : Natural := 0;
         Origin_Depth : Integer := -1;
      begin
         while Index <= Text'Last loop
            if Identifier (Text (Index)) then
               declare
                  First : constant Positive := Index;
               begin
                  while Index <= Text'Last and then Identifier (Text (Index))
                  loop
                     Index := Index + 1;
                  end loop;
                  if Text (First .. Index - 1) = "from" then
                     Origin_Depth := Depth;
                  elsif Origin_Depth < 0 then
                     Used.Include (Text (First .. Index - 1));
                  end if;
               end;
            else
               if Text (Index) = '(' then
                  Depth := Depth + 1;
               elsif Text (Index) = ')' then
                  if Origin_Depth = Depth then
                     Origin_Depth := -1;
                  end if;
                  if Depth > 0 then
                     Depth := Depth - 1;
                  end if;
               end if;
               Index := Index + 1;
            end if;
         end loop;
      end Reserve_Types;

      function Allocate (Wanted : String) return String;

      function Allocate (Wanted : String) return String is
         Named : US.Unbounded_String := US.To_Unbounded_String (Wanted);
      begin
         while Used.Contains (US.To_String (Named)) loop
            US.Append (Named, "_");
         end loop;
         Used.Include (US.To_String (Named));
         return US.To_String (Named);
      end Allocate;

      function Origins (Text : String) return String;

      function Origins (Text : String) return String is
         Written : US.Unbounded_String;
         Index : Natural := Text'First;
         Depth : Natural := 0;
         In_Origins : Boolean := False;
      begin
         while Index <= Text'Last loop
            if Identifier (Text (Index)) then
               declare
                  First : constant Positive := Index;
               begin
                  while Index <= Text'Last and then Identifier (Text (Index))
                  loop
                     Index := Index + 1;
                  end loop;
                  declare
                     Word : constant String := Text (First .. Index - 1);
                  begin
                     if Depth = 0 and then Word = "from" then
                        In_Origins := True;
                     end if;
                     US.Append
                       (Written,
                        (if In_Origins and then Answer.Names.Contains (Word)
                         then Answer.Names (Word) else Word));
                  end;
               end;
            else
               if Text (Index) = '(' then
                  Depth := Depth + 1;
               elsif Text (Index) = ')' and then Depth > 0 then
                  Depth := Depth - 1;
               end if;
               US.Append (Written, Text (Index));
               Index := Index + 1;
            end if;
         end loop;
         return US.To_String (Written);
      end Origins;
   begin
      for Parameter of Parameters loop
         declare
            Colon : constant Natural :=
              Ada.Strings.Fixed.Index (Parameter, ":");
         begin
            if Colon > 0 then
               Reserve_Types (Parameter (Colon + 1 .. Parameter'Last));
            end if;
         end;
      end loop;
      declare
         Colon : constant Natural := Ada.Strings.Fixed.Index (Result, ":");
      begin
         if Colon > 0 then
            Reserve_Types (Result (Colon + 1 .. Result'Last));
         end if;
      end;
      --  Preserve every available source name, including a suffix that an
      --  earlier parameter would otherwise claim while avoiding its type.
      for Parameter of Parameters loop
         declare
            Colon : constant Natural :=
              Ada.Strings.Fixed.Index (Parameter, ":");
         begin
            if Colon > 0 then
               declare
                  First : constant Positive := Name_Start (Parameter, Colon);
                  Named : constant String := Parameter (First .. Colon - 1);
               begin
                  if not Used.Contains (Named) then
                     Answer.Names.Insert (Named, Named);
                  end if;
               end;
            end if;
         end;
      end loop;
      for Position in Answer.Names.Iterate loop
         Used.Include (Text_Maps.Key (Position));
      end loop;
      for Parameter of Parameters loop
         declare
            Colon : constant Natural :=
              Ada.Strings.Fixed.Index (Parameter, ":");
         begin
            if Colon > 0 then
               declare
                  First : constant Positive := Name_Start (Parameter, Colon);
                  Named : constant String := Parameter (First .. Colon - 1);
               begin
                  if not Answer.Names.Contains (Named) then
                     Answer.Names.Insert (Named, Allocate (Named));
                  end if;
               end;
            end if;
         end;
      end loop;
      for Parameter of Parameters loop
         declare
            Colon : constant Natural :=
              Ada.Strings.Fixed.Index (Parameter, ":");
         begin
            if Colon = 0 then
               Answer.Parameters.Append (Parameter);
            else
               declare
                  First : constant Positive := Name_Start (Parameter, Colon);
                  Named : constant String := Parameter (First .. Colon - 1);
               begin
                  Answer.Parameters.Append
                    (Parameter (Parameter'First .. First - 1)
                     & Answer.Names (Named) & ":"
                     & Origins (Parameter (Colon + 1 .. Parameter'Last)));
               end;
            end if;
         end;
      end loop;
      declare
         Colon : constant Natural := Ada.Strings.Fixed.Index (Result, ":");
      begin
         if Colon = 0 then
            Answer.Result := US.To_Unbounded_String (Result);
         else
            declare
               First : constant Positive := Name_Start (Result, Colon);
               Named : constant String := Result (First .. Colon - 1);
            begin
               Answer.Result := US.To_Unbounded_String
                 (Result (Result'First .. First - 1) & Allocate (Named) & ":"
                  & Origins (Result (Colon + 1 .. Result'Last)));
            end;
         end if;
      end;
      return Answer;
   end Signature;

   function Ldn_Extern
     (S : Handle; Symbol, Named : String;
      Parameters : String_Vectors.Vector; Result : String;
      Owner_Context : String := "") return String;

   function Ldn_Extern
     (S : Handle; Symbol, Named : String;
      Parameters : String_Vectors.Vector; Result : String;
      Owner_Context : String := "") return String
   is
      Clean : constant String := T.Sanitize_Landin (Named);
      Allocated : constant Landin_Signature := Signature (Parameters, Result);
      Owner : constant String :=
        (if Owner_Context /= "" then Owner_Context
         else "generated adapter " & T.Repr (Symbol));
   begin
      if S.Landin_Names.Contains (Clean) then
         if S.Landin_Names (Clean) /= Owner then
            Fail (S, Owner & ": Landin name " & T.Repr (Clean)
                  & " collides with " & S.Landin_Names (Clean));
         end if;
      else
         Claim_Landin (S, Clean, Owner);
      end if;
      return "public extern(c) link(symbol: """ & Symbol & """) " & Clean
        & ": (" & T.Join (Allocated.Parameters, ", ") & ") -> "
        & US.To_String (Allocated.Result);
   end Ldn_Extern;

   No_Strings : constant String_Vectors.Vector := String_Vectors.Empty_Vector;

   function One (Item : String) return String_Vectors.Vector is
     (String_Vectors.To_Vector (Item, 1));

   function Two (First, Second : String) return String_Vectors.Vector is
     (One (First) & Second);

   function Three (First, Second, Third : String)
     return String_Vectors.Vector is (Two (First, Second) & Third);

   procedure Declare_Landin (S : Handle; Text : String);

   procedure Declare_Landin (S : Handle; Text : String) is
   begin
      S.Declarations.Append (Text);
   end Declare_Landin;

   ---------------------------------------------------------------------
   --  Enums, aliases and callbacks
   ---------------------------------------------------------------------

   procedure Render_Enum (S : Handle; Index : Positive);

   procedure Render_Enum (S : Handle; Index : Positive) is
      Identity : constant String := US.To_String (S.Enums (Index).Identity);
      Choice : constant Natural := Find (S.Enum_Entries, Identity);
      Where : constant String :=
        (if Choice /= 0 then Context (S, Choice)
         else "enum dependency " & T.Repr (C.Enum_Display (S, Index)));
   begin
      for Typedef_Name of S.Enums (Index).Typedef_Names loop
         Ensure_Typedef_Unattributed (S, Typedef_Name, Where);
      end loop;
      for Item of C.Inner (S, S.Enums (Index).Node) loop
         if T.Ends_With (C.Text (S, Item, "kind"), "Attr") then
            Fail (S, Where & ": enum packing or fixed-underlying attribute "
                  & C.Text (S, Item, "kind") & " is unsupported");
         end if;
      end loop;
      declare
         Underlying : constant Type_Id := Enum_Underlying (S, Index);
         Named : constant String := Landin_Name_For_Enum (S, Index);
         Size : constant Natural := Layout_Size (S, Underlying);
         Alignment : constant Natural := Layout_Alignment (S, Underlying);
         C_Name : constant String := C.Enum_C_Name (S, Index);
         Underlying_Text : constant String := C_Type_Text (S, Underlying);
         Lines : String_Vectors.Vector;
         Names, Values : String_Vectors.Vector;
         Constants : constant Meta_Id := T.List_Meta (S);
         Object : constant Meta_Id := T.Object_Meta (S);
      begin
         if C_Name /= "" then
            S.C_Assertions.Append
              ("_Static_assert(__builtin_types_compatible_p(" & C_Name & ", "
               & Underlying_Text & "), """ & C_Name
               & " compatible type disagrees with its generated integer"
               & " alias"");");
            S.C_Assertions.Append
              ("_Static_assert(sizeof(" & C_Name & ") == " & Number (Size)
               & ", """ & C_Name & " size disagrees with its generated"
               & " integer alias"");");
            S.C_Assertions.Append
              ("_Static_assert(_Alignof(" & C_Name & ") == "
               & Number (Alignment) & ", """ & C_Name & " alignment"
               & " disagrees with its generated integer alias"");");
         end if;
         Lines.Append
           ("public " & Named & ": type = "
            & Landin_Type (S, Underlying));
         Enum_Values (S, Index, Names, Values);
         for Position in 1 .. Natural (Names.Length) loop
            declare
               Clean : constant String := T.Sanitize_Landin (Names (Position));
               Item : constant Meta_Id := T.Object_Meta (S);
            begin
               Claim_Landin (S, Clean, Where & " constant");
               Lines.Append
                 ("public " & Clean & ": " & Named & " = "
                   & Values (Position));
               Put_Text (S, Item, "c_name", Names (Position));
               Put_Text (S, Item, "landin_name", Clean);
               T.Put (S, Item, "value", T.Number_Meta (S, Values (Position)));
               T.Append (S, Constants, Item);
            end;
         end loop;
         S.Type_Blocks.Append (T.Join (Lines, [1 => LF]));
         Put_Text (S, Object, "kind", "enum");
         if C_Name = "" then
            T.Put (S, Object, "c_name", T.Null_Meta (S));
         else
            Put_Text (S, Object, "c_name", C_Name);
         end if;
         Put_Text (S, Object, "landin_name", Named);
         Put_Text (S, Object, "underlying_c_type", Underlying_Text);
         Put_Text (S, Object, "representation", "integer-alias");
         Put_Number (S, Object, "size", Size);
         Put_Number (S, Object, "alignment", Alignment);
         T.Put (S, Object, "constants", Constants);
         Put_Flag (S, Object, "selected", Choice /= 0);
         S.Meta_Declarations.Append (Object);
      end;
   end Render_Enum;

   procedure Render_Alias (S : Handle; Alias_Name : String);

   procedure Render_Alias (S : Handle; Alias_Name : String) is
   begin
      Ensure_Typedef_Unattributed
        (S, Alias_Name, "typedef " & T.Repr (Alias_Name));
      declare
         Target : constant Type_Id := Get (S, C.Alias (S, Alias_Name)).Child;
      begin
         Ensure_Supported (S, Target, "typedef " & T.Repr (Alias_Name));
         if Resolved_Kind (S, Target) in Record_Type | Enum_Type
                                       | Callback_Type
         then
            return;
         end if;
         declare
            Landin_Name : constant String :=
              Landin_Name_For_Alias (S, Alias_Name);
            Rendered : constant String :=
              Landin_Type (S, Target, Site => Landin_Name);
            Object : constant Meta_Id := T.Object_Meta (S);
         begin
            S.Type_Blocks.Append
              ("public " & Landin_Name & ": type = " & Rendered);
            Put_Text (S, Object, "kind", "alias");
            Put_Text (S, Object, "c_name", Alias_Name);
            Put_Text (S, Object, "landin_name", Landin_Name);
            Put_Text (S, Object, "c_type", C_Type_Text (S, Target));
            Put_Text (S, Object, "representation", "type-alias");
            Put_Flag (S, Object, "selected",
                      S.Alias_Entries.Contains (Alias_Name));
            S.Meta_Declarations.Append (Object);
         end;
      end;
   end Render_Alias;

   procedure Callback_Annotation_Maps
     (S : Handle; Callback_Name : String; Callback : C_Type;
      Notes : out Annotation_Maps.Map; Result_Note : out Annotation);

   procedure Callback_Annotation_Maps
     (S : Handle; Callback_Name : String; Callback : C_Type;
      Notes : out Annotation_Maps.Map; Result_Note : out Annotation)
   is
      Choice : constant Natural := Find (S.Callback_Entries, Callback_Name);
      Raw_Params : constant J.Value :=
        (if Choice /= 0 then P.Field (S, Raw (S, Choice), "parameters")
         else J.No_Value);
      Policy_Names : constant String_Sets.Set := Key_Set (S, Raw_Params);
      Actual : String_Sets.Set;
      Label : constant String := "callback " & T.Repr (Callback_Name);
   begin
      Notes.Clear;
      Result_Note := No_Annotation;
      for Position in 1 .. Natural (Callback.Parameters.Length) loop
         Actual.Include ("argument_" & Number (Position));
      end loop;
      for Key of Policy_Names loop
         if not Actual.Contains (Key) then
            Fail (S, Label & ": parameter " & T.Repr (Key)
                  & " is absent (stale policy)");
         end if;
      end loop;
      for Position in 1 .. Natural (Callback.Parameters.Length) loop
         declare
            Parameter : constant Type_Id := Callback.Parameters (Position);
            Named : constant String := "argument_" & Number (Position);
         begin
            if Contains_Reference (S, Parameter) then
               if not Policy_Names.Contains (Named) then
                  Fail (S, Label & " parameter " & T.Repr (Named)
                        & ": missing required pointer policy");
               end if;
               declare
                  Note : constant Annotation := P.Annotation_Of
                    (S, P.Field (S, Raw_Params, Named),
                     Label & " parameter " & T.Repr (Named));
               begin
                  Notes.Include (Named, Note);
                  if Resolved_Kind (S, Parameter) = Callback_Type
                    and then Nullable (Note)
                  then
                     Fail (S, Label & " parameter " & T.Repr (Named)
                           & ": nested nullable callback is unsupported");
                  end if;
                  if not Note.From.Is_Empty then
                     Fail (S, Label & " parameter " & T.Repr (Named)
                           & ": from must be empty");
                  end if;
               end;
            elsif Policy_Names.Contains (Named) then
               Fail (S, Label & " parameter " & T.Repr (Named)
                     & ": a non-reference parameter takes no policy;"
                     & " remove " & T.Repr (Named) & " from ""parameters""");
            end if;
         end;
      end loop;
      if Contains_Reference (S, Callback.Result) then
         if Choice = 0 or else not P.Has (S, Raw (S, Choice), "result") then
            Fail (S, Label & " result: missing required pointer policy");
         end if;
         Result_Note := P.Annotation_Of
           (S, P.Field (S, Raw (S, Choice), "result"), Label & " result");
         if Resolved_Kind (S, Callback.Result) = Callback_Type
           and then Nullable (Result_Note)
         then
            Fail (S, Label & " result: nested nullable callback is"
                  & " unsupported");
         end if;
         declare
            Unknown : String_Sets.Set;
         begin
            for Source of Result_Note.From loop
               if not Actual.Contains (Source) then
                  Unknown.Include (Source);
               end if;
            end loop;
            if not Unknown.Is_Empty then
               Fail (S, Label & " result: from name "
                     & T.Repr (Unknown.First_Element) & " is absent");
            end if;
         end;
         if (for some Source of Result_Note.From =>
               not Notes.Contains (Source))
         then
            Fail (S, Label & " result: from must name reference-bearing"
                  & " parameters");
         end if;
      elsif Choice /= 0 and then P.Has (S, Raw (S, Choice), "result") then
         Fail (S, Label & " result: a non-reference result takes no"
               & " policy; remove the ""result"" key");
      end if;
   end Callback_Annotation_Maps;

   function Render_Callback_Cell
     (S : Handle; C_Name, L_Name : String; Callback : C_Type;
      Notes : Annotation_Maps.Map; Result_Note : Annotation) return Meta_Id;

   function Render_Callback_Cell
     (S : Handle; C_Name, L_Name : String; Callback : C_Type;
      Notes : Annotation_Maps.Map; Result_Note : Annotation) return Meta_Id
   is
      Stem : constant String := T.Sanitize_Landin (L_Name & "_cell");
      Optional : constant String := Optional_For (S, Stem, "ptr mut u8");
      Struct_Name : constant String := C_Symbol (S, C_Name, "cell_type");
   begin
      --  D938: a cell's allocate and release are calloc and free.
      if not Hosted (S.Chosen) then
         Fail (S, "callback " & T.Repr (C_Name) & ": a nullable callback's"
               & " cell allocates with calloc, and " & Target_Name (S.Chosen)
               & " is freestanding, with no C library; on "
               & Target_Name (S.Chosen) & " select the callback with"
               & " nullable: false and give its positions nonnullable policy");
      end if;
      S.Needs_Stdlib := True;
      --  A struct tag need not consume the function-symbol namespace.
      S.C_Symbols.Delete (Struct_Name);
      S.Cell_Structs.Include (C_Name, Struct_Name);
      S.C_Definitions.Append
        ("struct " & Struct_Name & " { " & C_Name & " value; };");
      declare
         Allocate : constant String := C_Symbol (S, C_Name, "cell_allocate");
         Release : constant String := C_Symbol (S, C_Name, "cell_release");
         Initialize : constant String :=
           C_Symbol (S, C_Name, "cell_initialize");
         Size_Name : constant String := C_Symbol (S, C_Name, "cell_size");
         Align_Name : constant String :=
           C_Symbol (S, C_Name, "cell_alignment");
         Clear : constant String := C_Symbol (S, C_Name, "cell_clear");
         Set_Name : constant String := C_Symbol (S, C_Name, "cell_set");
         Present : constant String := C_Symbol (S, C_Name, "cell_present");
         Access_Name : constant String := C_Symbol (S, C_Name, "cell_access");
         Invoke : constant String := C_Symbol (S, C_Name, "cell_invoke");
         Wanted : String_Vectors.Vector := Three ("cell", "value", "result");
      begin
         for Position in 1 .. Natural (Callback.Parameters.Length) loop
            Wanted.Append ("argument_" & Number (Position));
         end loop;
         declare
            Locals : constant String_Vectors.Vector := C_Locals (S, Wanted);
            Cell : constant String := Locals (1);
            Value : constant String := Locals (2);
            Output : constant String := Locals (3);
            Cast : constant String := "((struct " & Struct_Name & " *)" & Cell
              & ")";
            Const_Cast : constant String :=
              "((const struct " & Struct_Name & " *)" & Cell & ")";
            Invoke_Params : String_Vectors.Vector :=
              One ("const void *" & Cell);
            Call_Args : String_Vectors.Vector;
            Ldn_Invoke_Params : String_Vectors.Vector := One ("cell: ptr u8");
            Invoke_Body : String_Vectors.Vector;
            Symbols : Meta_Id;
         begin
            Add_C_Function
              (S, "void *", Allocate, No_Strings,
               One ("return calloc(1, sizeof(struct " & Struct_Name & "));"));
            Add_C_Function
              (S, "void", Release, One ("void *" & Cell),
               One ("free(" & Cell & ");"));
            Add_C_Function
              (S, "void", Initialize, One ("void *" & Cell),
               One (Cast & "->value = 0;"));
            Add_C_Function
              (S, "__SIZE_TYPE__", Size_Name, No_Strings,
               One ("return sizeof(struct " & Struct_Name & ");"));
            Add_C_Function
              (S, "__SIZE_TYPE__", Align_Name, No_Strings,
               One ("return _Alignof(struct " & Struct_Name & ");"));
            Add_C_Function
              (S, "void", Clear, One ("void *" & Cell),
               One (Cast & "->value = 0;"));
            Add_C_Function
              (S, "void", Set_Name,
               Two ("void *" & Cell, C_Name & " " & Value),
               One (Cast & "->value = " & Value & ";"));
            Add_C_Function
              (S, "_Bool", Present, One ("const void *" & Cell),
               One ("return " & Const_Cast & "->value != 0;"));
            Add_C_Function
              (S, C_Name, Access_Name, One ("const void *" & Cell),
               Three (C_Name & " " & Value & " = " & Const_Cast & "->value;",
                      "if (" & Value & " == 0) __builtin_trap();",
                      "return " & Value & ";"));
            for Position in 1 .. Natural (Callback.Parameters.Length) loop
               declare
                  Parameter : constant Type_Id :=
                    Callback.Parameters (Position);
                  Arg : constant String := "argument_" & Number (Position);
                  Local : constant String := Locals (3 + Position);
                  Declared : constant String :=
                    C_Declarator (S, Parameter, Local);
                  Rendered : constant String :=
                    Landin_Parameter
                      (S, Parameter, Arg, Lookup (Notes, Arg),
                       Stem & "_" & Arg,
                       Output_Store => Result_Note.From.Contains (Arg));
               begin
                  Invoke_Params.Append (Declared);
                  Call_Args.Append (Local);
                  Ldn_Invoke_Params.Append (Rendered);
               end;
            end loop;
            declare
               Call : constant String :=
                 Const_Cast & "->value(" & T.Join (Call_Args, ", ") & ")";
               Guard : constant String :=
                 "if (" & Const_Cast & "->value == 0) return 0;";
            begin
               if Is_Void (S, Resolve (S, Callback.Result)) then
                  Invoke_Body := Three (Guard, Call & ";", "return 1;");
               else
                  declare
                     Output_Type : constant Type_Id :=
                       Pointer_To (S, Callback.Result);
                     Declared : constant String :=
                       C_Declarator (S, Output_Type, Output);
                     Value_Type : constant String :=
                       Landin_Type (S, Callback.Result, Result_Note,
                                    Stem & "_invoke_result");
                  begin
                     Invoke_Params.Append (Declared);
                     Ldn_Invoke_Params.Append ("result: ptr mut "
                       & Value_Type);
                     Invoke_Body := Three
                       (Guard, "*" & Output & " = " & Call & ";", "return 1;");
                  end;
               end if;
            end;
            Add_C_Function (S, "_Bool", Invoke, Invoke_Params, Invoke_Body);
            declare
               D1 : constant String := Ldn_Extern
                 (S, Allocate, Stem & "_allocate", No_Strings,
                  "(cell: " & Optional & ")");
               D2 : constant String := Ldn_Extern
                 (S, Release, Stem & "_release", One ("cell: ptr mut u8"),
                  "none");
               D3 : constant String := Ldn_Extern
                 (S, Initialize, Stem & "_initialize",
                  One ("cell: ptr mut u8"), "none");
               D4 : constant String := Ldn_Extern
                 (S, Size_Name, Stem & "_size", No_Strings, "(size: usize)");
               D5 : constant String := Ldn_Extern
                 (S, Align_Name, Stem & "_alignment", No_Strings,
                  "(alignment: usize)");
               D6 : constant String := Ldn_Extern
                 (S, Clear, Stem & "_clear", One ("cell: ptr mut u8"), "none");
               D7 : constant String := Ldn_Extern
                 (S, Set_Name, Stem & "_set",
                  Two ("cell: ptr mut u8", "escaping value: " & L_Name),
                  "none");
               D8 : constant String := Ldn_Extern
                 (S, Present, Stem & "_present", One ("cell: ptr u8"),
                  "(present: bool)");
               D9 : constant String := Ldn_Extern
                 (S, Access_Name, Stem & "_access", One ("cell: ptr u8"),
                  "(value: " & L_Name & ")");
               D10 : constant String := Ldn_Extern
                 (S, Invoke, Stem & "_invoke", Ldn_Invoke_Params,
                  "(invoked: bool)");
            begin
               for Text of String_Vectors.Vector'
                 [D1, D2, D3, D4, D5, D6, D7, D8, D9, D10]
               loop
                  Declare_Landin (S, Text);
               end loop;
            end;
            Symbols := Symbols_Meta
              (S,
               String_Vectors.Vector'
                 ["allocate", "release", "initialize", "size", "alignment",
                  "clear", "set", "present", "access", "invoke"],
               String_Vectors.Vector'
                 [Allocate, Release, Initialize, Size_Name, Align_Name,
                  Clear, Set_Name, Present, Access_Name, Invoke]);
            return Symbols;
         end;
      end;
   end Render_Callback_Cell;

   procedure Render_Callback (S : Handle; Callback_Name : String);

   procedure Render_Callback (S : Handle; Callback_Name : String) is
      Label : constant String := "callback " & T.Repr (Callback_Name);
   begin
      Ensure_Typedef_Unattributed (S, Callback_Name, Label);
      declare
         Alias_Id : constant Type_Id := C.Alias (S, Callback_Name);
         Callback_Id : constant Type_Id := Resolve (S, Alias_Id);
         Callback : constant C_Type := Get (S, Callback_Id);
      begin
         if Callback.Kind /= Callback_Type then
            Fail (S, "typedef " & T.Repr (Callback_Name)
                  & " is not a callback");
         end if;
         Ensure_Supported (S, Alias_Id, Label);
         for Position in 1 .. Natural (Callback.Parameters.Length) loop
            if Opaque_By_Value (S, Callback.Parameters (Position)) then
               Fail (S, Label & " parameter" & Positive'Image (Position)
                     & ": C-owned opaque by-value type is unsupported");
            end if;
            if Pointer_Only (S, Callback.Parameters (Position)) then
               Fail (S, Label & " parameter" & Positive'Image (Position)
                     & ": a packed record by value has no extern(c)"
                     & " transport; C passes it only through a pointer"
                     & " (D414)");
            end if;
         end loop;
         if Opaque_By_Value (S, Callback.Result) then
            Fail (S, Label & " result: C-owned opaque by-value type is"
                  & " unsupported");
         end if;
         if Pointer_Only (S, Callback.Result) then
            Fail (S, Label & " result: a packed record by value has no"
                  & " extern(c) transport; C passes it only through a"
                  & " pointer (D414)");
         end if;
         declare
            Notes : Annotation_Maps.Map;
            Result_Note : Annotation;
         begin
            Callback_Annotation_Maps
              (S, Callback_Name, Callback, Notes, Result_Note);
            declare
               L_Name : constant String :=
                 Landin_Name_For_Alias (S, Callback_Name);
               Parameters : String_Vectors.Vector;
               Choice : constant Natural :=
                 Find (S.Callback_Entries, Callback_Name);
               Is_Nullable : constant Boolean :=
                 Choice /= 0 and then P.Is_True (S, Raw (S, Choice),
                   "nullable");
               Object : constant Meta_Id := T.Object_Meta (S);
               Parameter_Meta : constant Meta_Id := T.List_Meta (S);
               Names : Text_Maps.Map;
            begin
               for Position in 1 .. Natural (Callback.Parameters.Length) loop
                  declare
                     Named : constant String :=
                       "argument_" & Number (Position);
                     Rendered : constant String := Landin_Parameter
                       (S, Callback.Parameters (Position), Named,
                        Lookup (Notes, Named),
                        L_Name & "_argument_" & Number (Position));
                  begin
                     Parameters.Append (Rendered);
                  end;
               end loop;
               if Callback.Variadic then
                  Parameters.Append ("...");
               end if;
               declare
                  Result : constant String := Landin_Return
                    (S, Callback.Result, Result_Note, L_Name & "_result");
                  Allocated : constant Landin_Signature :=
                    Signature (Parameters, Result);
               begin
                  Names := Allocated.Names;
                  S.Type_Blocks.Append
                    ("public " & L_Name & ": type = extern(c) ("
                     & T.Join (Allocated.Parameters, ", ") & ") -> "
                     & US.To_String (Allocated.Result));
               end;
               for Position in 1 .. Natural (Callback.Parameters.Length) loop
                  declare
                     Named : constant String :=
                       "argument_" & Number (Position);
                     Item : constant Meta_Id := T.Object_Meta (S);
                  begin
                     Put_Text (S, Item, "c_name", Named);
                     Put_Text (S, Item, "landin_name", Names (Named));
                     Put_Text (S, Item, "c_type",
                               C_Type_Text (S,
                                 Callback.Parameters (Position)));
                     Put_Text (S, Item, "landin_type",
                               Landin_Type
                                 (S, Callback.Parameters (Position),
                                  Lookup (Notes, Named),
                                  L_Name & "_argument_" & Number (Position)));
                     T.Put (S, Item, "policy",
                            Note_Meta (S, Lookup (Notes, Named)));
                     T.Append (S, Parameter_Meta, Item);
                  end;
               end loop;
               Put_Text (S, Object, "kind", "callback");
               Put_Text (S, Object, "c_name", Callback_Name);
               Put_Text (S, Object, "landin_name", L_Name);
               Put_Flag (S, Object, "nullable_cell", Is_Nullable);
               Put_Flag (S, Object, "variadic", Callback.Variadic);
               T.Put (S, Object, "parameters", Parameter_Meta);
               T.Put (S, Object, "result",
                      Type_Metadata (S, Callback.Result, Result_Note,
                                     L_Name & "_result"));
               Put_Flag (S, Object, "selected", Choice /= 0);
               if Is_Nullable then
                  if Callback.Variadic then
                     Fail (S, Label & ": nullable variadic callback cell would"
                           & " require unsupported va_list forwarding");
                  end if;
                  T.Put (S, Object, "cell",
                         Render_Callback_Cell
                           (S, Callback_Name, L_Name, Callback, Notes,
                            Result_Note));
                  T.Put (S, Object, "adapter_output_escaping_sources",
                         T.Strings_Meta (S, Result_Note.From));
               end if;
               S.Meta_Declarations.Append (Object);
            end;
         end;
      end;
   end Render_Callback;

   ---------------------------------------------------------------------
   --  Records
   ---------------------------------------------------------------------

   procedure Render_Native_Record (S : Handle; Index : Positive);

   procedure Render_Native_Record (S : Handle; Index : Positive) is
      Named : constant String := Landin_Name_For_Record (S, Index);
      Packed : constant Boolean := C.Record_Packed (S, Index);
      Layout : constant String :=
        (if Packed then "layout(c, packed)" else "layout(c)");
      Identity : constant String := US.To_String (S.Records (Index).Identity);
      Lines : String_Vectors.Vector :=
        One ("public " & Named & ": type = " & Layout & " struct");
      Fields_Meta : constant Meta_Id := T.List_Meta (S);
   begin
      for Field of C.Record_Fields (S, Index) loop
         declare
            Field_Name : constant String := C.Text (S, Field, "name");
            Note : constant Annotation :=
              Lookup (S.Annotations, Field_Key (Identity, Field_Name));
            L_Field : constant String := T.Sanitize_Landin (Field_Name);
            Rendered : constant String :=
              Landin_Type (S, Type_Of (S, Field), Note,
                           Named & "_" & L_Field);
            C_Text : constant String := C_Type_Text (S, Type_Of (S, Field));
            Item : constant Meta_Id := T.Object_Meta (S);
         begin
            Lines.Append ("    " & L_Field & ": " & Rendered);
            Put_Text (S, Item, "c_name", Field_Name);
            Put_Text (S, Item, "landin_name", L_Field);
            Put_Text (S, Item, "c_type", C_Text);
            T.Put (S, Item, "policy", Note_Meta (S, Note));
            T.Append (S, Fields_Meta, Item);
         end;
      end loop;
      Lines.Append ("end " & Named);
      S.Type_Blocks.Append (T.Join (Lines, [1 => LF]));
      declare
         Size, Alignment : Natural;
         Offsets : Offset_Vectors.Vector;
         C_Name : constant String := C.Record_C_Name (S, Index);
         Flexible : constant J.Value := Flexible_Field (S, Index);
         Choice : constant Natural := Find (S.Record_Entries, Identity);
         Object : constant Meta_Id := T.Object_Meta (S);
         Offsets_Meta : constant Meta_Id := T.Object_Meta (S);
         Record_Id : constant Type_Id :=
           C.Make (S, (Kind => Record_Type,
                       Spelling => US.To_Unbounded_String (C_Name),
                       Name => US.To_Unbounded_String (Identity),
                       others => <>));
      begin
         Record_Layout (S, Index, String_Sets.Empty_Set, Size, Alignment,
                        Offsets);
         S.C_Assertions.Append
           ("_Static_assert(sizeof(" & C_Name & ") == " & Number (Size)
            & ", """ & C_Name & " size disagrees with Landin " & Layout
            & """);");
         S.C_Assertions.Append
           ("_Static_assert(_Alignof(" & C_Name & ") == " & Number (Alignment)
            & ", """ & C_Name & " alignment disagrees with Landin " & Layout
            & """);");
         for Each of Offsets loop
            S.C_Assertions.Append
              ("_Static_assert(__builtin_offsetof(" & C_Name & ", "
               & US.To_String (Each.Name) & ") == " & Number (Each.Offset)
               & ", """ & C_Name & "." & US.To_String (Each.Name)
               & " offset disagrees with Landin " & Layout & """);");
            Put_Number (S, Offsets_Meta, US.To_String (Each.Name),
              Each.Offset);
         end loop;
         Put_Text (S, Object, "kind", "record");
         Put_Text (S, Object, "c_name", C_Name);
         Put_Text (S, Object, "landin_name", Named);
         Put_Text (S, Object, "representation", Native_Layout);
         Put_Number (S, Object, "size", Size);
         Put_Number (S, Object, "alignment", Alignment);
         Put_Flag (S, Object, "packed", Packed);
         if J.Is_Present (Flexible) then
            Put_Text (S, Object, "flexible_member",
                      C.Text (S, Flexible, "name"));
         else
            T.Put (S, Object, "flexible_member", T.Null_Meta (S));
         end if;
         Put_Flag (S, Object, "pointer_only", Pointer_Only (S, Record_Id));
         T.Put (S, Object, "fields", Fields_Meta);
         T.Put (S, Object, "offsets", Offsets_Meta);
         Put_Flag (S, Object, "selected", Choice /= 0);
         S.Meta_Declarations.Append (Object);
      end;
   end Render_Native_Record;

   function Bitfield_Width (S : Handle; Field : J.Value) return Natural;

   function Bitfield_Width (S : Handle; Field : J.Value) return Natural is
   begin
      for Child of C.Inner (S, Field) loop
         if C.Text (S, Child, "kind") = "ConstantExpr"
           and then C.Has (S, Child, "value")
           and then T.Is_Digits (C.Text (S, Child, "value"))
           and then C.Text (S, Child, "value")'Length <= 9
         then
            return Natural'Value (C.Text (S, Child, "value"));
         end if;
      end loop;
      Fail (S, "Clang AST bitfield has no constant width", Clang_Fault);
   end Bitfield_Width;

   function Callback_Alias_Name (S : Handle; Id : Type_Id) return String is
     (if Kind (S, Id) = Alias_Type
         and then Resolved_Kind (S, Id) = Callback_Type
      then Name (S, Id) else "");

   function Render_Opaque_Field
     (S : Handle; Index : Positive; Record_Name, Field_Name : String;
      Id : Type_Id; Note : Annotation) return Meta_Id;

   function Render_Opaque_Field
     (S : Handle; Index : Positive; Record_Name, Field_Name : String;
      Id : Type_Id; Note : Annotation) return Meta_Id
   is
      Stem : constant String :=
        Record_Name & "_" & T.Sanitize_Landin (Field_Name);
      C_Name : constant String := C.Record_C_Name (S, Index);
      Locals : constant String_Vectors.Vector :=
        C_Locals (S, Three ("object", "value", "index"));
      Object : constant String := Locals (1);
      Value : constant String := Locals (2);
      Index_Local : constant String := Locals (3);
      Display : constant String := Record_Display (S, Index);
      Label : constant String :=
        "record " & Display & " field " & T.Repr (Field_Name);
      Read : constant String := "((const " & C_Name & " *)" & Object & ")->"
        & Field_Name;
      Written : constant String := "((" & C_Name & " *)" & Object & ")->"
        & Field_Name;
   begin
      Require_Storable_Policy (S, Id, Note, Label);
      declare
         Resolved : constant Type_Id := Resolve (S, Id);
         Item : constant C_Type := Get (S, Resolved);
      begin
         if Item.Kind = Callback_Type
           and then Callback_Alias_Name (S, Id) = ""
         then
            Fail (S, Label & ": opaque callback accessor requires a named"
                  & " function-pointer typedef");
         end if;
         if Item.Kind = Array_Type then
            declare
               Get_Name : constant String := C_Symbol (S, Stem, "get");
               Set_Name : constant String := C_Symbol (S, Stem, "set");
               Element : constant Type_Id := Item.Child;
               Bound : constant String :=
                 "if (" & Index_Local & " >= " & Image (Item.Count)
                 & ") __builtin_trap();";
            begin
               if Element = No_Type or else Item.Count <= 0 then
                  Fail (S, Stem & ": invalid array field");
               end if;
               if Resolved_Kind (S, Element) = Array_Type then
                  Fail (S, Label & ": nested array accessor is unsupported");
               end if;
               if Resolved_Kind (S, Element) = Callback_Type
                 and then Nullable (Note)
               then
                  Fail (S, Label & ": nullable callback array accessor is"
                        & " unsupported");
               end if;
               if By_Address (S, Element) then
                  declare
                     Element_Text : constant String :=
                       C_Type_Text (S, Element);
                  begin
                     Add_C_Function
                       (S, "void", Get_Name,
                        Three ("const void *" & Object,
                               "__SIZE_TYPE__ " & Index_Local,
                               "void *" & Value),
                        Two (Bound,
                             "*(" & Element_Text & " *)" & Value & " = "
                             & Read & "[" & Index_Local & "];"));
                     Add_C_Function
                       (S, "void", Set_Name,
                        Three ("void *" & Object,
                               "__SIZE_TYPE__ " & Index_Local,
                               "const void *" & Value),
                        Two (Bound,
                             Written & "[" & Index_Local & "] = *(const "
                             & Element_Text & " *)" & Value & ";"));
                  end;
                  declare
                     Source : constant String := Opaque_Get_Source (S,
                       Element);
                     Target : constant String :=
                       "value: " & Address_Type (S, Element, Mutable => True);
                     D1 : constant String := Ldn_Extern
                       (S, Get_Name, Stem & "_get",
                        Three (Source, "index: usize", Target), "none");
                     Setter_Value : constant String :=
                       Landin_Opaque_Parameter (S, Element, "value", Note);
                     D2 : constant String := Ldn_Extern
                       (S, Set_Name, Stem & "_set",
                        Three ("object: ptr mut u8", "index: usize",
                               Setter_Value), "none");
                  begin
                     Declare_Landin (S, D1);
                     Declare_Landin (S, D2);
                  end;
                  return Symbols_Meta
                    (S, Two ("get", "set"), Two (Get_Name, Set_Name));
               end if;
               declare
                  Element_Text : constant String := C_Type_Text (S, Element);
               begin
                  Add_C_Function
                    (S, Element_Text, Get_Name,
                     Two ("const void *" & Object,
                          "__SIZE_TYPE__ " & Index_Local),
                     Two (Bound,
                          "return " & Read & "[" & Index_Local & "];"));
               end;
               declare
                  Declared : constant String :=
                    C_Declarator (S, Element, Value);
               begin
                  Add_C_Function
                    (S, "void", Set_Name,
                     Three ("void *" & Object, "__SIZE_TYPE__ " & Index_Local,
                            Declared),
                     Two (Bound,
                          Written & "[" & Index_Local & "] = " & Value & ";"));
               end;
               declare
                  L_Type : constant String :=
                    Landin_Type (S, Element, Note, Stem & "_element");
                  L_Value : constant String :=
                    Landin_Parameter (S, Element, "value", Note,
                                      Stem & "_element");
                  Returned : constant String :=
                    Field_Return (S, Element, L_Type);
                  D1 : constant String := Ldn_Extern
                    (S, Get_Name, Stem & "_get",
                     Two ("object: ptr u8", "index: usize"), Returned);
                  D2 : constant String := Ldn_Extern
                    (S, Set_Name, Stem & "_set",
                     Three ("object: ptr mut u8", "index: usize", L_Value),
                     "none");
               begin
                  Declare_Landin (S, D1);
                  Declare_Landin (S, D2);
               end;
               return Symbols_Meta
                 (S, Two ("get", "set"), Two (Get_Name, Set_Name));
            end;
         end if;
         if Item.Kind = Callback_Type and then Nullable (Note) then
            if Item.Variadic then
               Fail (S, Label & ": nullable variadic callback requires"
                     & " unsupported va_list forwarding");
            end if;
            declare
               Clear : constant String := C_Symbol (S, Stem, "clear");
               Set_Name : constant String := C_Symbol (S, Stem, "set");
               Present : constant String := C_Symbol (S, Stem, "present");
               Access_Name : constant String := C_Symbol (S, Stem, "access");
               Declared : constant String := C_Declarator (S, Id, Value);
               Value_Text : constant String := C_Type_Text (S, Id);
            begin
               Add_C_Function
                 (S, "void", Clear, One ("void *" & Object),
                  One (Written & " = 0;"));
               Add_C_Function
                 (S, "void", Set_Name, Two ("void *" & Object, Declared),
                  One (Written & " = " & Value & ";"));
               Add_C_Function
                 (S, "_Bool", Present, One ("const void *" & Object),
                  One ("return " & Read & " != 0;"));
               Add_C_Function
                 (S, Value_Text, Access_Name, One ("const void *" & Object),
                  Three (Declared & " = " & Read & ";",
                         "if (" & Value & " == 0) __builtin_trap();",
                         "return " & Value & ";"));
               declare
                  L_Type : constant String := Landin_Type (S, Id, Site
                    => Stem);
                  L_Value : constant String :=
                    Landin_Parameter (S, Id, "value", Note, Stem);
                  D1 : constant String := Ldn_Extern
                    (S, Clear, Stem & "_clear", One ("object: ptr mut u8"),
                     "none");
                  D2 : constant String := Ldn_Extern
                    (S, Set_Name, Stem & "_set",
                     Two ("object: ptr mut u8", L_Value), "none");
                  D3 : constant String := Ldn_Extern
                    (S, Present, Stem & "_present", One ("object: ptr u8"),
                     "(present: bool)");
                  Returned : constant String := Field_Return (S, Id, L_Type);
                  D4 : constant String := Ldn_Extern
                    (S, Access_Name, Stem & "_access", One ("object: ptr u8"),
                     Returned);
               begin
                  Declare_Landin (S, D1);
                  Declare_Landin (S, D2);
                  Declare_Landin (S, D3);
                  Declare_Landin (S, D4);
               end;
               return Symbols_Meta
                 (S, String_Vectors.Vector'["clear", "set", "present",
                   "access"],
                  String_Vectors.Vector'[Clear, Set_Name, Present,
                    Access_Name]);
            end;
         end if;
         if By_Address (S, Id) then
            declare
               Get_Name : constant String := C_Symbol (S, Stem, "get");
               Set_Name : constant String := C_Symbol (S, Stem, "set");
               Nested : constant String := C_Type_Text (S, Id);
            begin
               Add_C_Function
                 (S, "void", Get_Name,
                  Two ("const void *" & Object, "void *" & Value),
                  One ("*(" & Nested & " *)" & Value & " = " & Read & ";"));
               Add_C_Function
                 (S, "void", Set_Name,
                  Two ("void *" & Object, "const void *" & Value),
                  One (Written & " = *(const " & Nested & " *)" & Value
                       & ";"));
               declare
                  Source : constant String := Opaque_Get_Source (S, Id);
                  Target : constant String :=
                    "value: " & Address_Type (S, Id, Mutable => True);
                  D1 : constant String := Ldn_Extern
                    (S, Get_Name, Stem & "_get", Two (Source, Target), "none");
                  Setter_Value : constant String :=
                    Landin_Opaque_Parameter (S, Id, "value", Note);
                  D2 : constant String := Ldn_Extern
                    (S, Set_Name, Stem & "_set",
                     Two ("object: ptr mut u8", Setter_Value), "none");
               begin
                  Declare_Landin (S, D1);
                  Declare_Landin (S, D2);
               end;
               return Symbols_Meta
                 (S, Two ("get", "set"), Two (Get_Name, Set_Name));
            end;
         end if;
         declare
            Get_Name : constant String := C_Symbol (S, Stem, "get");
            Set_Name : constant String := C_Symbol (S, Stem, "set");
            Value_Text : constant String := C_Type_Text (S, Id);
            Declared : constant String := C_Declarator (S, Id, Value);
         begin
            Add_C_Function
              (S, Value_Text, Get_Name, One ("const void *" & Object),
               One ("return " & Read & ";"));
            Add_C_Function
              (S, "void", Set_Name, Two ("void *" & Object, Declared),
               One (Written & " = " & Value & ";"));
            declare
               L_Type : constant String := Landin_Type (S, Id, Note, Stem);
               L_Value : constant String :=
                 Landin_Parameter (S, Id, "value", Note, Stem);
               Returned : constant String := Field_Return (S, Id, L_Type);
               D1 : constant String := Ldn_Extern
                 (S, Get_Name, Stem & "_get", One ("object: ptr u8"),
                  Returned);
               D2 : constant String := Ldn_Extern
                 (S, Set_Name, Stem & "_set",
                  Two ("object: ptr mut u8", L_Value), "none");
            begin
               Declare_Landin (S, D1);
               Declare_Landin (S, D2);
            end;
            return Symbols_Meta
              (S, Two ("get", "set"), Two (Get_Name, Set_Name));
         end;
      end;
   end Render_Opaque_Field;

   procedure Render_Opaque_Record (S : Handle; Index : Positive);

   procedure Render_Opaque_Record (S : Handle; Index : Positive) is
      Named : constant String := Landin_Name_For_Record (S, Index);
      Identity : constant String := US.To_String (S.Records (Index).Identity);
      Choice : constant Natural := Find (S.Record_Entries, Identity);
      C_Name : constant String := C.Record_C_Name (S, Index);
      Object : constant Meta_Id := T.Object_Meta (S);
   begin
      if not C.Record_Complete (S, Index) then
         S.Type_Blocks.Append
           ("-- " & Named & " is an incomplete C-owned object; pointers to it"
            & " are opaque byte pointers.");
         Put_Text (S, Object, "kind", "record");
         Put_Text (S, Object, "c_name", C_Name);
         Put_Text (S, Object, "landin_name", Named);
         Put_Text (S, Object, "representation", Incomplete);
         Put_Flag (S, Object, "selected", Choice /= 0);
         S.Meta_Declarations.Append (Object);
         return;
      end if;
      --  D938: a freestanding target has no calloc and free, so its
      --  C-owned objects live in storage the caller supplies, by their
      --  size and alignment, and have no allocate and release.
      S.Needs_Stdlib := S.Needs_Stdlib or else Hosted (S.Chosen);
      declare
         Optional : constant String :=
           (if Hosted (S.Chosen)
            then Optional_For (S, Named & "_object", "ptr mut u8") else "");
         Allocate : constant String :=
           (if Hosted (S.Chosen) then C_Symbol (S, Named, "allocate")
            else "");
         Release : constant String :=
           (if Hosted (S.Chosen) then C_Symbol (S, Named, "release")
            else "");
         Copy : constant String := C_Symbol (S, Named, "copy");
         Size_Name : constant String := C_Symbol (S, Named, "size");
         Align_Name : constant String := C_Symbol (S, Named, "alignment");
         Locals : constant String_Vectors.Vector :=
           C_Locals (S, Three ("object", "target", "source"));
         Object_Local : constant String := Locals (1);
         Target_Local : constant String := Locals (2);
         Source_Local : constant String := Locals (3);
         Record_Id : constant Type_Id :=
           C.Make (S, (Kind => Record_Type,
                       Spelling => US.To_Unbounded_String (C_Name),
                       Name => US.To_Unbounded_String (Identity),
                       others => <>));
         Fields_Meta : constant Meta_Id := T.List_Meta (S);
         Unnamed_Index : Natural := 0;
      begin
         if Hosted (S.Chosen) then
            Add_C_Function
              (S, "void *", Allocate, No_Strings,
               One ("return calloc(1, sizeof(" & C_Name & "));"));
            Add_C_Function
              (S, "void", Release, One ("void *" & Object_Local),
               One ("free(" & Object_Local & ");"));
         end if;
         Add_C_Function
           (S, "void", Copy,
            Two ("void *" & Target_Local, "const void *" & Source_Local),
            One ("*(" & C_Name & " *)" & Target_Local & " = *(const " & C_Name
                 & " *)" & Source_Local & ";"));
         Add_C_Function
           (S, "__SIZE_TYPE__", Size_Name, No_Strings,
            One ("return sizeof(" & C_Name & ");"));
         Add_C_Function
           (S, "__SIZE_TYPE__", Align_Name, No_Strings,
            One ("return _Alignof(" & C_Name & ");"));
         if Hosted (S.Chosen) then
            Declare_Landin
              (S, Ldn_Extern
                 (S, Allocate, Named & "_allocate", No_Strings,
                  "(object: " & Optional & ")"));
            Declare_Landin
              (S, Ldn_Extern
                 (S, Release, Named & "_release", One ("object: ptr mut u8"),
                  "none"));
         end if;
         declare
            Store : constant Boolean := Contains_Reference (S, Record_Id);
            Source : constant String := Landin_Opaque_Parameter
              (S, Record_Id, "source", Output_Store => Store);
            D3 : constant String := Ldn_Extern
              (S, Copy, Named & "_copy", Two ("target: ptr mut u8", Source),
               "none");
            D4 : constant String := Ldn_Extern
              (S, Size_Name, Named & "_size", No_Strings, "(size: usize)");
            D5 : constant String := Ldn_Extern
              (S, Align_Name, Named & "_alignment", No_Strings,
               "(alignment: usize)");
         begin
            for Text of String_Vectors.Vector'[D3, D4, D5] loop
               Declare_Landin (S, Text);
            end loop;
         end;
         for Field of C.Record_Fields (S, Index) loop
            declare
               Field_Type : constant Type_Id := Type_Of (S, Field);
               Field_Name : constant String := C.Text (S, Field, "name");
               Is_Bitfield : constant Boolean :=
                 C.Truthy (S, Field, "isBitfield");
               Width : Natural := 0;
               Item : constant Meta_Id := T.Object_Meta (S);
            begin
               if Is_Bitfield then
                  Width := Bitfield_Width (S, Field);
               end if;
               if Field_Name = "" then
                  Unnamed_Index := Unnamed_Index + 1;
                  T.Put (S, Item, "c_name", T.Null_Meta (S));
                  if Is_Bitfield then
                     Put_Number (S, Item, "bit_width", Width);
                  else
                     T.Put (S, Item, "bit_width", T.Null_Meta (S));
                  end if;
                  Put_Number (S, Item, "unnamed_index", Unnamed_Index);
                  Put_Text (S, Item, "c_type", C_Type_Text (S, Field_Type));
                  T.Put (S, Item, "accessors", T.Object_Meta (S));
               else
                  declare
                     Note : constant Annotation :=
                       Lookup (S.Annotations, Field_Key (Identity,
                         Field_Name));
                     Accessors : constant Meta_Id :=
                       Render_Opaque_Field
                         (S, Index, Named, Field_Name, Field_Type, Note);
                  begin
                     Put_Text (S, Item, "c_name", Field_Name);
                     Put_Text (S, Item, "landin_name",
                               T.Sanitize_Landin (Field_Name));
                     Put_Text (S, Item, "c_type", C_Type_Text (S, Field_Type));
                     if Is_Bitfield then
                        Put_Number (S, Item, "bit_width", Width);
                     else
                        T.Put (S, Item, "bit_width", T.Null_Meta (S));
                     end if;
                     T.Put (S, Item, "policy", Note_Meta (S, Note));
                     T.Put (S, Item, "accessors", Accessors);
                  end;
               end if;
               T.Append (S, Fields_Meta, Item);
            end;
         end loop;
         Put_Text (S, Object, "kind", "record");
         Put_Text (S, Object, "c_name", C_Name);
         Put_Text (S, Object, "landin_name", Named);
         Put_Text (S, Object, "representation", Opaque_Storage);
         Put_Text (S, Object, "record_kind",
                   (if C.Record_Union (S, Index) then "union" else "struct"));
         T.Put (S, Object, "lifecycle",
                Symbols_Meta
                  (S,
                   String_Vectors.Vector'
                     ["allocate", "release", "copy", "size", "alignment"],
                   String_Vectors.Vector'
                     [Allocate, Release, Copy, Size_Name, Align_Name]));
         T.Put (S, Object, "fields", Fields_Meta);
         Put_Flag (S, Object, "selected", Choice /= 0);
         S.Meta_Declarations.Append (Object);
      end;
   end Render_Opaque_Record;

   procedure Render_Record (S : Handle; Index : Positive);

   procedure Render_Record (S : Handle; Index : Positive) is
   begin
      if Record_Classification (S, Index) = Native_Layout then
         Render_Native_Record (S, Index);
      else
         Render_Opaque_Record (S, Index);
      end if;
   end Render_Record;

   ---------------------------------------------------------------------
   --  Functions, incoming variadic entries and variables
   ---------------------------------------------------------------------

   function Require_Nullable_Cell
     (S : Handle; Id : Type_Id; Where : String) return String;

   function Require_Nullable_Cell
     (S : Handle; Id : Type_Id; Where : String) return String
   is
      Alias_Name : constant String := Callback_Alias_Name (S, Id);
   begin
      if Alias_Name = "" then
         Fail (S, Where & ": nullable callback requires a named"
               & " function-pointer typedef");
      end if;
      declare
         Choice : constant Natural := Find (S.Callback_Entries, Alias_Name);
      begin
         if Choice = 0 or else not P.Is_True (S, Raw (S, Choice), "nullable")
         then
            Fail (S, Where & ": callback typedef " & T.Repr (Alias_Name)
                  & " needs a selected nullable callback policy");
         end if;
      end;
      S.Needed_Callbacks.Include (Alias_Name);
      return Alias_Name;
   end Require_Nullable_Cell;

   procedure Check_Nullable_Cell (S : Handle; Id : Type_Id; Where : String);

   procedure Check_Nullable_Cell (S : Handle; Id : Type_Id; Where : String)
   is
      Ignored : constant String := Require_Nullable_Cell (S, Id, Where);
      pragma Unreferenced (Ignored);
   begin
      null;
   end Check_Nullable_Cell;

   procedure Render_Function (S : Handle; Rooted : Selection);

   procedure Render_Function (S : Handle; Rooted : Selection) is
      Choice : constant Positive := Rooted.Choice;
      Node : constant J.Value := Rooted.Node;
      Where : constant String := Context (S, Choice);
      L_Name : constant String := Entry_Landin (S, Choice);
      C_Name : constant String := Entry_Name (S, Choice);
      Params : Value_Vectors.Vector;
      Result : Type_Id;
      Notes : Annotation_Maps.Map;
      Result_Note : Annotation;
   begin
      Validate_Function_Shape (S, Choice, Node, Params, Result);
      Validate_Site_Annotations (S, Choice, Params, Result, Notes,
                                 Result_Note);
      declare
         Variadic : constant Boolean := C.Truthy (S, Node, "variadic");
         Has_Statement : constant Boolean := Has_Body (S, Node);
         Storage : constant String := C.Text (S, Node, "storageClass");
         Inline : constant Boolean := C.Truthy (S, Node, "inline");
         Reasons : String_Vectors.Vector;
      begin
         if Variadic and then Params.Is_Empty then
            Fail (S, Where & ": C variadic declaration needs at least one"
                  & " fixed parameter");
         end if;
         if Storage = "static" and then not Has_Statement then
            Fail (S, Where & ": bodyless static function has no callable"
                  & " definition");
         end if;
         if Inline and then Storage /= "static" then
            Fail (S, Where & ": external inline semantics are unsupported");
         end if;
         if Storage = "static" or else Inline then
            Reasons.Append ("internal-or-inline");
         end if;
         for Index in 1 .. Natural (Params.Length) loop
            declare
               Item : constant Type_Id := Type_Of (S, Params (Index));
               Named : constant String :=
                 Parameter_Name (S, Params (Index), Index);
            begin
               if Opaque_By_Value (S, Item) then
                  Reasons.Append ("opaque-parameter:" & Named);
               elsif Pointer_Only (S, Item) then
                  Reasons.Append ("pointer-only-parameter:" & Named);
               end if;
               if Resolved_Kind (S, Item) = Callback_Type
                 and then Nullable (Lookup (Notes, Named))
               then
                  Check_Nullable_Cell
                    (S, Item, Where & " parameter " & T.Repr (Named));
                  Reasons.Append ("nullable-callback:" & Named);
               end if;
            end;
         end loop;
         if Opaque_By_Value (S, Result) then
            Reasons.Append ("opaque-result");
         elsif Pointer_Only (S, Result) then
            Reasons.Append ("pointer-only-result");
         end if;
         if Resolved_Kind (S, Result) = Callback_Type
           and then Nullable (Result_Note)
         then
            Check_Nullable_Cell (S, Result, Where & " result");
            Reasons.Append ("nullable-callback-result");
         end if;
         if P.Text (S, Raw (S, Choice), "direction") = "export" then
            if Storage = "static" or else Inline or else Has_Statement then
               Fail (S, Where & ": export must name an external bodyless"
                     & " declaration");
            end if;
            if Variadic then
               Fail (S, Where & ": variadic export must use kind"
                     & " incoming_varargs");
            end if;
            if not Reasons.Is_Empty then
               Fail (S, Where & ": export requires a native C signature;"
                     & " adapter-required form " & Reasons.First_Element
                     & " is unsupported");
            end if;
            declare
               Object : constant Meta_Id := T.Object_Meta (S);
            begin
               Put_Text (S, Object, "kind", "function");
               Put_Text (S, Object, "c_name", C_Name);
               Put_Text (S, Object, "landin_name", L_Name);
               Put_Text (S, Object, "direction", "export");
               Put_Flag (S, Object, "variadic", Variadic);
               T.Put (S, Object, "adapter", T.Null_Meta (S));
               T.Put (S, Object, "parameters",
                      Function_Parameter_Metadata (S, Params, Notes, L_Name));
               T.Put (S, Object, "result",
                      Type_Metadata (S, Result, Result_Note,
                                     L_Name & "_result"));
               S.Meta_Declarations.Append (Object);
            end;
            return;
         end if;
         if Variadic and then not Reasons.Is_Empty then
            Fail (S, Where & ": adapter-required variadic call needs"
                  & " unsupported va_list forwarding ("
                  & Reasons.First_Element & ")");
         end if;
         declare
            Wanted : String_Vectors.Vector := One ("result");
         begin
            for Index in 1 .. Natural (Params.Length) loop
               Wanted.Append ("argument_" & Number (Index));
            end loop;
            declare
               Locals : constant String_Vectors.Vector := C_Locals (S, Wanted);
               Output_Local : constant String := Locals (1);
               Output_Result : constant Boolean :=
                 Reasons.Contains ("opaque-result")
                 or else Reasons.Contains ("pointer-only-result")
                 or else Reasons.Contains ("nullable-callback-result");
               Output_Sources : constant String_Vectors.Vector :=
                 (if Output_Result and then Result_Note.Present
                  then Result_Note.From else No_Strings);
               Parameter_Names : String_Sets.Set;
               Output_Name : US.Unbounded_String :=
                 US.To_Unbounded_String ("result");
               C_Decls, Call_Arguments, Ldn_Parameters : String_Vectors.Vector;
               Link_Symbol : US.Unbounded_String :=
                 US.To_Unbounded_String (C_Name);
               Ldn_Result : US.Unbounded_String;
               Adapter : US.Unbounded_String;
            begin
               for Index in 1 .. Natural (Params.Length) loop
                  Parameter_Names.Include
                    (T.Sanitize_Landin
                       (Parameter_Name (S, Params (Index), Index)));
               end loop;
               while Parameter_Names.Contains (US.To_String (Output_Name))
               loop
                  US.Append (Output_Name, "_");
               end loop;
               for Index in 1 .. Natural (Params.Length) loop
                  declare
                     Item : constant Type_Id := Type_Of (S, Params (Index));
                     Named : constant String :=
                       Parameter_Name (S, Params (Index), Index);
                     Local : constant String := Locals (1 + Index);
                     Note : constant Annotation := Lookup (Notes, Named);
                     Stored : constant Boolean :=
                       Output_Sources.Contains (Named);
                  begin
                     if By_Address (S, Item) then
                        declare
                           Text : constant String := C_Type_Text (S, Item);
                           Rendered : constant String :=
                             Landin_Opaque_Parameter
                               (S, Item, Named, Note, Stored);
                        begin
                           C_Decls.Append ("const void *" & Local);
                           Call_Arguments.Append
                             ("*(const " & Text & " *)" & Local);
                           Ldn_Parameters.Append (Rendered);
                        end;
                     elsif Resolved_Kind (S, Item) = Callback_Type
                       and then Nullable (Note)
                     then
                        declare
                           Alias_Name : constant String :=
                             Require_Nullable_Cell
                               (S, Item, Where & " parameter "
                                & T.Repr (Named));
                           Tag : constant String :=
                             S.Cell_Structs (Alias_Name);
                           Escaping : constant String :=
                             Escaping_Prefix (S, Item, Note, Stored);
                        begin
                           C_Decls.Append ("const void *" & Local);
                           Call_Arguments.Append
                             ("((const struct " & Tag & " *)" & Local
                              & ")->value");
                           Ldn_Parameters.Append
                             (Escaping & T.Sanitize_Landin (Named)
                              & ": ptr u8");
                        end;
                     else
                        declare
                           Declared : constant String :=
                             C_Declarator (S, Item, Local);
                           Rendered : constant String :=
                             Landin_Parameter
                               (S, Item, Named, Note,
                                L_Name & "_" & T.Sanitize_Landin (Named),
                                Stored);
                        begin
                           C_Decls.Append (Declared);
                           Call_Arguments.Append (Local);
                           Ldn_Parameters.Append (Rendered);
                        end;
                     end if;
                  end;
               end loop;
               if Variadic then
                  Ldn_Parameters.Append ("...");
               end if;
               if not Reasons.Is_Empty then
                  Adapter := US.To_Unbounded_String
                    (C_Symbol (S, C_Name, "call"));
                  Link_Symbol := Adapter;
                  declare
                     Call : constant String :=
                       C_Name & "(" & T.Join (Call_Arguments, ", ") & ")";
                     Body_Lines : String_Vectors.Vector;
                     C_Result : US.Unbounded_String;
                  begin
                     if By_Address (S, Result) then
                        declare
                           Target : constant String :=
                             Address_Type (S, Result, Mutable => True);
                        begin
                           C_Decls.Prepend ("void *" & Output_Local);
                           Ldn_Parameters.Prepend
                             (US.To_String (Output_Name) & ": " & Target);
                        end;
                        Body_Lines := One
                          ("*(" & C_Type_Text (S, Result) & " *)"
                           & Output_Local & " = " & Call & ";");
                        C_Result := US.To_Unbounded_String ("void");
                        Ldn_Result := US.To_Unbounded_String ("none");
                     elsif Resolved_Kind (S, Result) = Callback_Type
                       and then Nullable (Result_Note)
                     then
                        declare
                           Alias_Name : constant String :=
                             Require_Nullable_Cell
                               (S, Result, Where & " result");
                           Tag : constant String :=
                             S.Cell_Structs (Alias_Name);
                        begin
                           C_Decls.Prepend ("void *" & Output_Local);
                           Ldn_Parameters.Prepend
                             (US.To_String (Output_Name) & ": ptr mut u8");
                           Body_Lines := One
                             ("((struct " & Tag & " *)" & Output_Local
                              & ")->value = " & Call & ";");
                        end;
                        C_Result := US.To_Unbounded_String ("void");
                        Ldn_Result := US.To_Unbounded_String ("none");
                     elsif Is_Void (S, Resolve (S, Result)) then
                        Body_Lines := One (Call & ";");
                        C_Result := US.To_Unbounded_String ("void");
                        Ldn_Result := US.To_Unbounded_String ("none");
                     else
                        Body_Lines := One ("return " & Call & ";");
                        C_Result := US.To_Unbounded_String
                          (C_Type_Text (S, Result));
                        Ldn_Result := US.To_Unbounded_String
                          (Landin_Return (S, Result, Result_Note,
                                          L_Name & "_result"));
                     end if;
                     Add_C_Function
                       (S, US.To_String (C_Result), US.To_String (Adapter),
                        C_Decls, Body_Lines);
                  end;
               else
                  Ldn_Result := US.To_Unbounded_String
                    (Landin_Return (S, Result, Result_Note,
                                    L_Name & "_result"));
               end if;
               declare
                  Allocated : constant Landin_Signature :=
                    Signature (Ldn_Parameters, US.To_String (Ldn_Result));
                  Object : constant Meta_Id := T.Object_Meta (S);
               begin
                  Declare_Landin
                    (S, Ldn_Extern
                       (S, US.To_String (Link_Symbol), L_Name,
                        Allocated.Parameters, US.To_String (Allocated.Result),
                        Owner_Context => Where));
                  Put_Text (S, Object, "kind", "function");
                  Put_Text (S, Object, "c_name", C_Name);
                  Put_Text (S, Object, "landin_name", L_Name);
                  Put_Text (S, Object, "direction", "import");
                  Put_Flag (S, Object, "variadic", Variadic);
                  if US.Length (Adapter) = 0 then
                     T.Put (S, Object, "adapter", T.Null_Meta (S));
                  else
                     Put_Text (S, Object, "adapter", US.To_String (Adapter));
                  end if;
                  T.Put (S, Object, "adapter_reasons",
                         T.Strings_Meta (S, Reasons));
                  T.Put (S, Object, "adapter_output_escaping_sources",
                         T.Strings_Meta (S, Output_Sources));
                  T.Put (S, Object, "parameters",
                         Function_Parameter_Metadata
                           (S, Params, Notes, L_Name, Allocated.Names));
                  T.Put (S, Object, "result",
                         Type_Metadata (S, Result, Result_Note,
                                        L_Name & "_result"));
                  S.Meta_Declarations.Append (Object);
               end;
            end;
         end;
      end;
   end Render_Function;

   procedure Render_Incoming_Varargs (S : Handle; Rooted : Selection);

   procedure Render_Incoming_Varargs (S : Handle; Rooted : Selection) is
      Choice : constant Positive := Rooted.Choice;
      Node : constant J.Value := Rooted.Node;
      Where : constant String := Context (S, Choice);
      L_Name : constant String := Entry_Landin (S, Choice);
      C_Name : constant String := Entry_Name (S, Choice);
      Schema : constant Value_Vectors.Vector :=
        P.Elements (S, P.Field (S, Raw (S, Choice), "schema"));
      Params : Value_Vectors.Vector;
      Result : Type_Id;
      Notes : Annotation_Maps.Map;
      Result_Note : Annotation;
      Names : String_Vectors.Vector;
   begin
      Validate_Function_Shape (S, Choice, Node, Params, Result);
      if not C.Truthy (S, Node, "variadic") then
         Fail (S, Where & ": incoming_varargs must name a variadic header"
               & " declaration");
      end if;
      if C.Text (S, Node, "storageClass") = "static"
        or else C.Truthy (S, Node, "inline") or else Has_Body (S, Node)
      then
         Fail (S, Where & ": incoming_varargs must name an external bodyless"
               & " declaration");
      end if;
      if Params.Is_Empty then
         Fail (S, Where & ": incoming varargs needs at least one fixed"
               & " parameter");
      end if;
      Validate_Site_Annotations (S, Choice, Params, Result, Notes,
                                 Result_Note);
      for Index in 1 .. Natural (Params.Length) loop
         declare
            Named : constant String := Parameter_Name (S, Params (Index),
              Index);
         begin
            if Resolved_Kind (S, Type_Of (S, Params (Index))) = Callback_Type
              and then Nullable (Lookup (Notes, Named))
            then
               Fail (S, Where & " parameter " & T.Repr (Named)
                     & ": nullable callback fixed parameter is unsupported"
                     & " for incoming varargs");
            end if;
         end;
      end loop;
      if Resolved_Kind (S, Result) = Callback_Type
        and then Nullable (Result_Note)
      then
         Fail (S, Where & " result: nullable callback result is unsupported"
               & " for incoming varargs");
      end if;
      for Parameter of Params loop
         if Opaque_By_Value (S, Type_Of (S, Parameter)) then
            Fail (S, Where & ": opaque fixed parameter is unsupported for"
                  & " incoming varargs");
         end if;
      end loop;
      if Opaque_By_Value (S, Result) then
         Fail (S, Where & ": opaque result is unsupported for incoming"
               & " varargs");
      end if;
      declare
         Any_Pointer_Only : Boolean := Pointer_Only (S, Result);
      begin
         for Parameter of Params loop
            exit when Any_Pointer_Only;
            Any_Pointer_Only := Pointer_Only (S, Type_Of (S, Parameter));
         end loop;
         if Any_Pointer_Only then
            Fail (S, Where & ": a packed record by value has no extern(c)"
                  & " transport for an incoming varargs handler; C passes it"
                  & " only through a pointer (D414)");
         end if;
      end;
      for Index in 1 .. Natural (Params.Length) loop
         Names.Append (Parameter_Name (S, Params (Index), Index));
      end loop;
      declare
         Handler_Names : String_Sets.Set;
         Collide : Boolean := False;
      begin
         for Named of Names loop
            Collide := Collide
              or else Handler_Names.Contains (T.Sanitize_Landin (Named));
            Handler_Names.Include (T.Sanitize_Landin (Named));
         end loop;
         for Item of Schema loop
            declare
               Clean : constant String :=
                 T.Sanitize_Landin (P.Text (S, Item, "name"));
            begin
               Collide := Collide or else Handler_Names.Contains (Clean);
               Handler_Names.Include (Clean);
            end;
         end loop;
         if Collide then
            Fail (S, Where & ": fixed and schema names collide after Landin"
                  & " normalization");
         end if;
      end;
      declare
         Count_Name : constant String :=
           P.Text (S, Raw (S, Choice), "count_parameter");
      begin
         if not Names.Contains (Count_Name) then
            Fail (S, Where & ": count_parameter " & T.Repr (Count_Name)
                  & " is absent from header (stale policy)");
         end if;
         declare
            Count_Index : constant Positive := Names.Find_Index (Count_Name);
            Count_Type : constant Type_Id :=
              Resolve (S, Type_Of (S, Params (Count_Index)));
         begin
            if Kind (S, Count_Type) not in Builtin_Type | Enum_Type
              or else (Kind (S, Count_Type) = Builtin_Type
                       and then Name (S, Count_Type)
                                in "float" | "double" | "_Bool" | "void")
            then
               Fail (S, Where & ": count_parameter must have an integer type");
            end if;
            declare
               Wanted : String_Vectors.Vector;
            begin
               for Index in 1 .. Natural (Params.Length) loop
                  Wanted.Append ("fixed_" & Number (Index));
               end loop;
               for Index in 1 .. Natural (Schema.Length) loop
                  Wanted.Append ("tail_" & Number (Index));
               end loop;
               Wanted.Append ("arguments");
               declare
                  Locals : constant String_Vectors.Vector :=
                    C_Locals (S, Wanted);
                  Fixed_Count : constant Natural := Natural (Params.Length);
                  Arguments_Local : constant String := Locals.Last_Element;
                  Fixed_C_Decls, Fixed_Calls : String_Vectors.Vector;
                  Handler_C_Decls, Handler_Ldn : String_Vectors.Vector;
                  Tail_C_Decls, Tail_Ldn : String_Vectors.Vector;
                  Extraction, Tail_Calls : String_Vectors.Vector;
                  Schema_Meta : constant Meta_Id := T.List_Meta (S);
                  Handler : constant String :=
                    P.Text (S, Raw (S, Choice), "handler");
               begin
                  for Index in 1 .. Fixed_Count loop
                     declare
                        Item : constant Type_Id := Type_Of (S, Params (Index));
                        Source_Name : constant String := Names (Index);
                        Local : constant String := Locals (Index);
                        Declared : constant String :=
                          C_Declarator (S, Item, Local);
                        Prototype : constant String :=
                          C_Prototype_Parameter (S, Item, Source_Name);
                        Rendered : constant String :=
                          Landin_Parameter
                            (S, Item, Source_Name, Lookup (Notes, Source_Name),
                             L_Name & "_" & T.Sanitize_Landin (Source_Name));
                     begin
                        Fixed_C_Decls.Append (Declared);
                        Fixed_Calls.Append (Local);
                        Handler_C_Decls.Append (Prototype);
                        Handler_Ldn.Append (Rendered);
                     end;
                  end loop;
                  for Index in 1 .. Natural (Schema.Length) loop
                     declare
                        Item : constant J.Value := Schema (Index);
                        Promoted : constant String :=
                          P.Text (S, Item, "promoted");
                        C_Spelling : constant String :=
                          (if Promoted = "c_int" then "int"
                           elsif Promoted = "c_uint" then "unsigned int"
                           elsif Promoted = "c_long" then "long"
                           elsif Promoted = "c_ulong" then "unsigned long"
                           elsif Promoted = "c_longlong" then "long long"
                           elsif Promoted = "c_ulonglong"
                           then "unsigned long long"
                           elsif Promoted = "c_double" then "double"
                           else "void *");
                        Item_Type : constant Type_Id :=
                          C.Parse (S, C_Spelling);
                        Tail_Name : constant String := P.Text (S, Item,
                          "name");
                        Note : Annotation := No_Annotation;
                        Local : constant String := Locals (Fixed_Count
                          + Index);
                     begin
                        if Promoted = "pointer" then
                           Note := P.Annotation_Of
                             (S, P.Field (S, Item, "policy"),
                              Where & " schema item" & Positive'Image (Index));
                           if not Note.From.Is_Empty then
                              Fail (S, Where & " schema item"
                                    & Positive'Image (Index)
                                    & ": from must be empty");
                           end if;
                        end if;
                        declare
                           Prototype : constant String :=
                             C_Prototype_Parameter (S, Item_Type, Tail_Name);
                           Rendered : constant String :=
                             Landin_Parameter
                               (S, Item_Type, Tail_Name, Note,
                                L_Name & "_" & T.Sanitize_Landin (Tail_Name));
                           Declared : constant String :=
                             C_Declarator (S, Item_Type, Local);
                           Item_Text : constant String :=
                             C_Type_Text (S, Item_Type);
                           Entry_Meta : constant Meta_Id := T.Object_Meta (S);
                        begin
                           Tail_C_Decls.Append (Prototype);
                           Tail_Ldn.Append (Rendered);
                           Extraction.Append
                             (Declared & " = va_arg(" & Arguments_Local & ", "
                              & Item_Text & ");");
                           Tail_Calls.Append (Local);
                           Put_Text (S, Entry_Meta, "name", Tail_Name);
                           Put_Text (S, Entry_Meta, "promoted", Promoted);
                           Put_Text (S, Entry_Meta, "c_type", C_Spelling);
                           Put_Text (S, Entry_Meta, "landin_type",
                                     Landin_Type
                                       (S, Item_Type, Note,
                                        L_Name & "_" & Tail_Name));
                           T.Put (S, Entry_Meta, "policy", Note_Meta (S,
                             Note));
                           T.Append (S, Schema_Meta, Entry_Meta);
                        end;
                     end;
                  end loop;
                  S.Needs_Stdarg := True;
                  declare
                     Handler_Result : constant String := C_Type_Text (S,
                       Result);
                     All_Handler : constant String_Vectors.Vector :=
                       Handler_C_Decls & Tail_C_Decls;
                     Count_Local : constant String := Locals (Count_Index);
                     Count_Text : constant String :=
                       C_Type_Text (S, Type_Of (S, Params (Count_Index)));
                     Body_Lines : String_Vectors.Vector;
                     Call : constant String :=
                       Handler & "("
                       & T.Join (Fixed_Calls & Tail_Calls, ", ") & ")";
                  begin
                     S.Export_Declarations.Append
                       (Handler_Result & " " & Handler & "("
                        & (if All_Handler.Is_Empty then "void"
                           else T.Join (All_Handler, ", ")) & ");");
                     Body_Lines.Append
                       ("if (" & Count_Local & " != (" & Count_Text & ")"
                        & Number (Natural (Schema.Length))
                        & ") __builtin_trap();");
                     Body_Lines.Append ("va_list " & Arguments_Local & ";");
                     Body_Lines.Append
                       ("va_start(" & Arguments_Local & ", "
                        & Locals (Fixed_Count) & ");");
                     Body_Lines.Append (Extraction);
                     Body_Lines.Append ("va_end(" & Arguments_Local & ");");
                     if Is_Void (S, Resolve (S, Result)) then
                        Body_Lines.Append (Call & ";");
                     else
                        Body_Lines.Append ("return " & Call & ";");
                     end if;
                     Add_C_Function
                       (S, Handler_Result, C_Name, Fixed_C_Decls & "...",
                        Body_Lines);
                  end;
                  declare
                     Handler_Type : constant String := Claim_Generated_Landin
                       (S, L_Name & "_handler", Where & " handler type");
                     Ldn_Return : constant String :=
                       Landin_Return (S, Result, Result_Note,
                                      L_Name & "_handler_result");
                     Allocated : constant Landin_Signature :=
                       Signature (Handler_Ldn & Tail_Ldn, Ldn_Return);
                     Object : constant Meta_Id := T.Object_Meta (S);
                  begin
                     S.Type_Blocks.Append
                       ("public " & Handler_Type & ": type = extern(c) ("
                        & T.Join (Allocated.Parameters, ", ") & ") -> "
                        & US.To_String (Allocated.Result));
                     Put_Text (S, Object, "kind", "incoming_varargs");
                     Put_Text (S, Object, "c_name", C_Name);
                     Put_Text (S, Object, "landin_name", L_Name);
                     Put_Text (S, Object, "handler", Handler);
                     Put_Text (S, Object, "handler_type", Handler_Type);
                     Put_Text (S, Object, "count_parameter", Count_Name);
                     T.Put (S, Object, "fixed_parameters",
                            Function_Parameter_Metadata
                              (S, Params, Notes, L_Name, Allocated.Names));
                     T.Put (S, Object, "schema", Schema_Meta);
                     T.Put (S, Object, "result",
                            Type_Metadata (S, Result, Result_Note,
                                           L_Name & "_handler_result"));
                     S.Meta_Declarations.Append (Object);
                  end;
               end;
            end;
         end;
      end;
   end Render_Incoming_Varargs;

   procedure Render_Variable (S : Handle; Rooted : Selection);

   procedure Render_Variable (S : Handle; Rooted : Selection) is
      Choice : constant Positive := Rooted.Choice;
      Node : constant J.Value := Rooted.Node;
      Where : constant String := Context (S, Choice);
      C_Name : constant String := Entry_Name (S, Choice);
      Stem : constant String := Entry_Landin (S, Choice);
      Note : Annotation := No_Annotation;
   begin
      for Item of C.Inner (S, Node) loop
         if T.Ends_With (C.Text (S, Item, "kind"), "Attr") then
            Fail (S, Where & ": unsupported variable attribute "
                  & C.Text (S, Item, "kind"));
         end if;
      end loop;
      declare
         Id : constant Type_Id := Type_Of (S, Node);
      begin
         Ensure_Supported (S, Id, Where);
         if Contains_Reference (S, Id) then
            if not P.Has (S, Raw (S, Choice), "value") then
               Fail (S, Where & ": value is missing required pointer policy");
            end if;
            Note := P.Annotation_Of
              (S, P.Field (S, Raw (S, Choice), "value"), Where & " value");
            if not Note.From.Is_Empty then
               Fail (S, Where & " value: from must be empty");
            end if;
         elsif P.Has (S, Raw (S, Choice), "value") then
            Fail (S, Where & ": stale value policy for non-reference object");
         end if;
         declare
            Resolved : constant Type_Id := Resolve (S, Id);
            Resolved_Const : constant Boolean := Get (S, Resolved).Const;
            Writable : constant Boolean :=
              P.Is_True (S, Raw (S, Choice), "writable");
            Read_Only : constant Boolean := Resolved_Const
              or else not Writable;
            Storage : constant String :=
              P.Text (S, Raw (S, Choice), "storage");
            Thread_Local : constant Boolean := C.Truthy (S, Node, "tls");
         begin
            --  D938: on Arm a thread-local object is reached through
            --  the C library's __aeabi_read_tp.
            if Thread_Local and then not Hosted (S.Chosen) then
               Fail (S, Where & ": a _Thread_local object is reached through"
                     & " the C library's thread pointer, and "
                     & Target_Name (S.Chosen) & " is freestanding, with no"
                     & " C library; select an object that is not"
                     & " thread-local");
            end if;
            if Kind (S, Resolved) = Callback_Type
              and then Callback_Alias_Name (S, Id) = ""
            then
               Fail (S, Where & ": callback object adapter requires a named"
                     & " function-pointer typedef");
            end if;
            if Writable then
               Require_Storable_Policy (S, Id, Note, Where & " value");
            end if;
            if Writable and then Resolved_Const then
               Fail (S, Where & ": const object cannot be writable");
            end if;
            for Declaration of S.Variables (C_Name) loop
               if C.Text (S, Declaration, "storageClass") /= "extern" then
                  Fail (S, Where & ": variable policy requires only external"
                        & " header declarations");
               end if;
            end loop;
            for Declaration of S.Variables (C_Name) loop
               if C.Has (S, Declaration, "init") then
                  Fail (S, Where & ": initialized variable definition in a"
                        & " header is unsupported");
               end if;
            end loop;
            if Storage = "define" then
               if Resolved_Const then
                  Fail (S, Where & ": zero-initialized const definition is"
                        & " unsupported");
               end if;
               if Note.Present and then not Nullable (Note) then
                  Fail (S, Where & ": zero-initialized pointer/callback"
                        & " definition must be nullable");
               end if;
               S.C_Definitions.Append
                 ((if Thread_Local then "_Thread_local " else "")
                  & C_Declarator (S, Id, C_Name) & ";");
            end if;
            declare
               Address : constant String := C_Symbol (S, C_Name, "address");
               Read_Name : constant String := C_Symbol (S, C_Name, "read");
               Write_Name : constant String :=
                 (if Writable then C_Symbol (S, C_Name, "write") else "");
               Nullable_Callback : Boolean;
               Opaque : Boolean;
               By_Address_Value : Boolean;
               Extra_Keys, Extra_Values : String_Vectors.Vector;
            begin
               if Kind (S, Resolved) = Array_Type then
                  Fail (S, Where & ": array object adapters are unsupported");
               end if;
               Nullable_Callback := Kind (S, Resolved) = Callback_Type
                 and then Nullable (Note);
               Opaque := Opaque_By_Value (S, Id);
               By_Address_Value := Opaque or else Pointer_Only (S, Id);
               declare
                  Local_Value : constant String := C_Local (S, "value");
                  Unqualified : constant Type_Id :=
                    C.With_Const (S, Id, False);
               begin
                  if Nullable_Callback then
                     Check_Nullable_Cell (S, Id, Where & " value");
                     declare
                        Clear_Name : constant String :=
                          (if Writable then C_Symbol (S, C_Name, "clear")
                           else "");
                        Present_Name : constant String :=
                          C_Symbol (S, C_Name, "present");
                        Address_C : constant String :=
                          (if Read_Only then "const void *" else "void *");
                        Address_Landin : constant String :=
                          (if Read_Only then "ptr u8" else "ptr mut u8");
                     begin
                        Add_C_Function
                          (S, Address_C, Address, No_Strings,
                           One ("return (" & Address_C & ")&" & C_Name & ";"));
                        Add_C_Function
                          (S, C_Type_Text (S, Unqualified), Read_Name,
                           No_Strings,
                           Two ("if (" & C_Name & " == 0) __builtin_trap();",
                                "return " & C_Name & ";"));
                        if Writable then
                           Add_C_Function
                             (S, "void", Write_Name,
                              One (C_Declarator (S, Id, Local_Value)),
                              One (C_Name & " = " & Local_Value & ";"));
                           Add_C_Function
                             (S, "void", Clear_Name, No_Strings,
                              One (C_Name & " = 0;"));
                        end if;
                        Add_C_Function
                          (S, "_Bool", Present_Name, No_Strings,
                           One ("return " & C_Name & " != 0;"));
                        declare
                           L_Callback : constant String :=
                             Landin_Type (S, Id, Site => Stem & "_callback");
                           D1 : constant String := Ldn_Extern
                             (S, Address, Stem & "_address", No_Strings,
                              "(address: " & Address_Landin & ")");
                           D2 : constant String := Ldn_Extern
                             (S, Read_Name, Stem & "_read", No_Strings,
                              "(value: " & L_Callback & ")");
                           D3 : constant String := Ldn_Extern
                             (S, Present_Name, Stem & "_present", No_Strings,
                              "(present: bool)");
                        begin
                           Declare_Landin (S, D1);
                           Declare_Landin (S, D2);
                           Declare_Landin (S, D3);
                        end;
                        if Writable then
                           declare
                              L_Parameter : constant String :=
                                Landin_Parameter (S, Id, "value", Note,
                                                  Stem & "_callback");
                              D4 : constant String := Ldn_Extern
                                (S, Clear_Name, Stem & "_clear", No_Strings,
                                 "none");
                              D5 : constant String := Ldn_Extern
                                (S, Write_Name, Stem & "_write",
                                 One (L_Parameter), "none");
                           begin
                              Declare_Landin (S, D4);
                              Declare_Landin (S, D5);
                           end;
                        end if;
                        Extra_Keys := Two ("clear", "present");
                        Extra_Values := Two (Clear_Name, Present_Name);
                     end;
                  elsif By_Address_Value then
                     declare
                        Address_C : constant String :=
                          (if Read_Only then "const void *" else "void *");
                        Address_Landin : constant String :=
                          Address_Type (S, Id, Mutable => not Read_Only);
                        Plain : constant String := C_Type_Text (S,
                          Unqualified);
                     begin
                        Add_C_Function
                          (S, Address_C, Address, No_Strings,
                           One ("return (" & Address_C & ")&" & C_Name & ";"));
                        Add_C_Function
                          (S, "void", Read_Name, One ("void *" & Local_Value),
                           One ("*(" & Plain & " *)" & Local_Value & " = "
                                & C_Name & ";"));
                        if Writable then
                           Add_C_Function
                             (S, "void", Write_Name,
                              One ("const void *" & Local_Value),
                              One (C_Name & " = *(const " & Plain & " *)"
                                   & Local_Value & ";"));
                        end if;
                        declare
                           D1 : constant String := Ldn_Extern
                             (S, Address, Stem & "_address", No_Strings,
                              "(address: " & Address_Landin & ")");
                           Target : constant String :=
                             "value: " & Address_Type (S, Id, Mutable => True);
                           D2 : constant String := Ldn_Extern
                             (S, Read_Name, Stem & "_read", One (Target),
                              "none");
                        begin
                           Declare_Landin (S, D1);
                           Declare_Landin (S, D2);
                        end;
                        if Writable then
                           declare
                              L_Parameter : constant String :=
                                Landin_Opaque_Parameter
                                  (S, Id, "value", Note);
                              D3 : constant String := Ldn_Extern
                                (S, Write_Name, Stem & "_write",
                                 One (L_Parameter), "none");
                           begin
                              Declare_Landin (S, D3);
                           end;
                        end if;
                     end;
                  else
                     declare
                        Address_Value : constant Type_Id :=
                          (if Read_Only then C.With_Const (S, Id, True)
                           else Id);
                        Pointer : constant Type_Id :=
                          Pointer_To (S, Address_Value);
                     begin
                        Add_C_Function
                          (S, C_Type_Text (S, Pointer), Address, No_Strings,
                           One ("return &" & C_Name & ";"));
                        Add_C_Function
                          (S, C_Type_Text (S, Unqualified), Read_Name,
                           No_Strings, One ("return " & C_Name & ";"));
                        if Writable then
                           Add_C_Function
                             (S, "void", Write_Name,
                              One (C_Declarator (S, Id, Local_Value)),
                              One (C_Name & " = " & Local_Value & ";"));
                        end if;
                        declare
                           L_Value : constant String :=
                             Landin_Type (S, Id, Note, Stem & "_value");
                           D1 : constant String := Ldn_Extern
                             (S, Address, Stem & "_address", No_Strings,
                              "(address: ptr "
                              & (if Read_Only then "" else "mut ") & L_Value
                              & ")");
                           D2 : constant String := Ldn_Extern
                             (S, Read_Name, Stem & "_read", No_Strings,
                              "(value: " & L_Value & ")");
                        begin
                           Declare_Landin (S, D1);
                           Declare_Landin (S, D2);
                        end;
                        if Writable then
                           declare
                              L_Parameter : constant String :=
                                Landin_Parameter (S, Id, "value", Note,
                                                  Stem & "_value");
                              D3 : constant String := Ldn_Extern
                                (S, Write_Name, Stem & "_write",
                                 One (L_Parameter), "none");
                           begin
                              Declare_Landin (S, D3);
                           end;
                        end if;
                     end;
                  end if;
               end;
               declare
                  Object : constant Meta_Id := T.Object_Meta (S);
                  Accessors : constant Meta_Id :=
                    Symbols_Meta
                      (S, Three ("address", "read", "write") & Extra_Keys,
                       Three (Address, Read_Name, Write_Name) & Extra_Values);
               begin
                  Put_Text (S, Object, "kind", "variable");
                  Put_Text (S, Object, "c_name", C_Name);
                  Put_Text (S, Object, "landin_name", Stem);
                  Put_Text (S, Object, "storage", Storage);
                  Put_Flag (S, Object, "thread_local", Thread_Local);
                  Put_Flag (S, Object, "writable", Writable);
                  Put_Text (S, Object, "c_type", C_Type_Text (S, Id));
                  if Opaque then
                     Put_Text (S, Object, "landin_type", "opaque-object");
                  else
                     Put_Text (S, Object, "landin_type",
                               Landin_Type (S, Id, Note, Stem & "_value"));
                  end if;
                  T.Put (S, Object, "policy", Note_Meta (S, Note));
                  T.Put (S, Object, "accessors", Accessors);
                  S.Meta_Declarations.Append (Object);
               end;
            end;
         end;
      end;
   end Render_Variable;

   ---------------------------------------------------------------------
   --  Ordering and the outputs
   ---------------------------------------------------------------------

   --  Records in dependency order: a record a native record holds by
   --  value comes before it.
   function Record_Order (S : Handle) return String_Vectors.Vector;

   function Record_Order (S : Handle) return String_Vectors.Vector is
      Result : String_Vectors.Vector;
      Visiting, Done : String_Sets.Set;

      procedure Visit (Identity : String);

      procedure Visit (Identity : String) is
         Index : constant Positive := C.Record_Index (S, Identity);
      begin
         if Done.Contains (Identity) then
            return;
         end if;
         if Visiting.Contains (Identity) then
            Fail (S, "recursive by-value record dependency");
         end if;
         Visiting.Include (Identity);
         if C.Record_Complete (S, Index) then
            for Field of C.Record_Fields (S, Index) loop
               declare
                  Field_Type : Type_Id := Resolve (S, Type_Of (S, Field));
               begin
                  while Kind (S, Field_Type) = Array_Type
                    and then Get (S, Field_Type).Child /= No_Type
                  loop
                     Field_Type := Resolve (S, Get (S, Field_Type).Child);
                  end loop;
                  if Kind (S, Field_Type) = Record_Type
                    and then S.Needed_Records.Contains (Name (S, Field_Type))
                  then
                     Visit (Name (S, Field_Type));
                  end if;
               end;
            end loop;
         end if;
         Visiting.Exclude (Identity);
         Done.Include (Identity);
         Result.Append (Identity);
      end Visit;

      Identities : constant String_Vectors.Vector :=
        Snapshot (S.Needed_Records);
      Displays : String_Vectors.Vector;
   begin
      for Identity of Identities loop
         Displays.Append
           (C.Record_Display (S, C.Record_Index (S, Identity)));
      end loop;
      for Identity of Sorted_Order (Displays, Identities) loop
         Visit (Identity);
      end loop;
      return Result;
   end Record_Order;

   procedure Claim_Dependency (S : Handle; Name, Owner : String);

   procedure Claim_Dependency (S : Handle; Name, Owner : String) is
   begin
      if S.Landin_Names.Contains (Name) then
         if S.Landin_Names (Name) /= Owner then
            Fail (S, Owner & ": Landin name " & T.Repr (Name)
                  & " collides with " & S.Landin_Names (Name));
         end if;
      else
         Claim_Landin (S, Name, Owner);
      end if;
   end Claim_Dependency;

   procedure Claim_Dependency_Names (S : Handle);

   procedure Claim_Dependency_Names (S : Handle) is
   begin
      for Identity of Snapshot (S.Needed_Enums) loop
         declare
            Index : constant Positive := C.Enum_Index (S, Identity);
            Choice : constant Natural := Find (S.Enum_Entries, Identity);
         begin
            Claim_Dependency
              (S, Landin_Name_For_Enum (S, Index),
               (if Choice /= 0 then Context (S, Choice)
                else "enum dependency "
                     & T.Repr (C.Enum_Display (S, Index))));
         end;
      end loop;
      declare
         Names : String_Sets.Set := S.Needed_Aliases;
      begin
         Names.Union (S.Needed_Callbacks);
         for Alias_Name of Snapshot (Names) loop
            declare
               Choice : Natural := Find (S.Alias_Entries, Alias_Name);
            begin
               if Choice = 0 then
                  Choice := Find (S.Callback_Entries, Alias_Name);
               end if;
               Claim_Dependency
                 (S, Landin_Name_For_Alias (S, Alias_Name),
                  (if Choice /= 0 then Context (S, Choice)
                   else "typedef dependency " & T.Repr (Alias_Name)));
            end;
         end loop;
      end;
      for Identity of Snapshot (S.Needed_Records) loop
         declare
            Index : constant Positive := C.Record_Index (S, Identity);
            Choice : constant Natural := Find (S.Record_Entries, Identity);
         begin
            Claim_Dependency
              (S, Landin_Name_For_Record (S, Index),
               (if Choice /= 0 then Context (S, Choice)
                else "record dependency " & Record_Display (S, Index)));
         end;
      end loop;
   end Claim_Dependency_Names;

   function Sorted_Selections
     (S : Handle; Items : Selection_Vectors.Vector)
      return Selection_Vectors.Vector;

   function Sorted_Selections
     (S : Handle; Items : Selection_Vectors.Vector)
      return Selection_Vectors.Vector
   is
      Keys, Ties : String_Vectors.Vector;
      Result : Selection_Vectors.Vector;
   begin
      for Position in 1 .. Natural (Items.Length) loop
         Keys.Append (Entry_Name (S, Items (Position).Choice));
         Ties.Append (Padded (Position));
      end loop;
      for Position of Sorted_Order (Keys, Ties) loop
         Result.Append (Items (Positive'Value (Position)));
      end loop;
      return Result;
   end Sorted_Selections;

   procedure Generate (S : Handle; Defines : Landin.Platform.Path_List) is
   begin
      Collect_Dependencies (S);
      Claim_Dependency_Names (S);
      for Identity of Probe_Order (S) loop
         Render_Enum (S, C.Enum_Index (S, Identity));
      end loop;
      for Callback_Name of Snapshot (S.Needed_Callbacks) loop
         Render_Callback (S, Callback_Name);
      end loop;
      for Alias_Name of Snapshot (S.Needed_Aliases) loop
         Render_Alias (S, Alias_Name);
      end loop;
      for Identity of Record_Order (S) loop
         Render_Record (S, C.Record_Index (S, Identity));
      end loop;
      for Rooted of Sorted_Selections (S, S.Function_Entries) loop
         Render_Function (S, Rooted);
      end loop;
      for Rooted of Sorted_Selections (S, S.Variable_Entries) loop
         Render_Variable (S, Rooted);
      end loop;
      for Rooted of Sorted_Selections (S, S.Incoming_Entries) loop
         Render_Incoming_Varargs (S, Rooted);
      end loop;

      declare
         Fact_Text : constant String := Fact (S.Chosen);
         Sections : String_Vectors.Vector;
         Optional_Blocks : String_Vectors.Vector;
         Double : constant String := LF & LF;
      begin
         for Cursor in S.Optionals.Iterate loop
            declare
               Item : constant Optional_Type := Optional_Maps.Element (Cursor);
            begin
               Optional_Blocks.Append
                 ("public " & US.To_String (Item.Absent) & ": atom" & LF
                  & "public " & US.To_String (Item.Name) & ": type = "
                  & US.To_String (Item.Absent) & " | "
                  & US.To_String (Item.Member_Type));
            end;
         end loop;
         Sections.Append
           ("-- Generated by refine bindings; do not edit.");
         Sections.Append
           ("-- landin/compiler is implicit and must not be imported.");
         Sections.Append
           ("import platform/c" & Double & "compiler.assert(compiler."
            & Fact_Text & ")"
            & (if Float_Guard (S.Chosen) = "" then ""
               else LF & "compiler.assert(" & Float_Guard (S.Chosen) & ")"));
         if not Optional_Blocks.Is_Empty then
            Sections.Append (T.Join (Optional_Blocks, Double));
         end if;
         if not S.Type_Blocks.Is_Empty then
            Sections.Append (T.Join (S.Type_Blocks, Double));
         end if;
         if not S.Declarations.Is_Empty then
            Sections.Append (T.Join (S.Declarations, Double));
         end if;
         declare
            Bindings : constant String := T.Join (Sections, Double) & LF;
            Guard : constant String :=
              "LANDIN_" & T.Upper (US.To_String (S.Namespace)) & "_BINDINGS_H";
            Export_Lines : String_Vectors.Vector;
            C_Lines : String_Vectors.Vector;
         begin
            Export_Lines.Append
              ("/* Generated by refine bindings; do not edit. */");
            Export_Lines.Append ("#ifndef " & Guard);
            Export_Lines.Append ("#define " & Guard);
            Export_Lines.Append ("");
            for Each of S.Headers loop
               Export_Lines.Append
                 ("#include """ & US.To_String (Each.Logical) & """");
            end loop;
            if not S.Headers.Is_Empty then
               Export_Lines.Append ("");
            end if;
            Export_Lines.Append (S.Export_Declarations);
            for Each of S.C_Functions loop
               Export_Lines.Append
                 (US.To_String (Each.Result) & " " & US.To_String (Each.Name)
                  & "(" & (if Each.Parameters.Is_Empty then "void"
                           else T.Join (Each.Parameters, ", ")) & ");");
            end loop;
            Export_Lines.Append ("");
            Export_Lines.Append ("#endif /* " & Guard & " */");

            C_Lines.Append
              ("/* Generated by refine bindings; do not edit. */");
            C_Lines.Append ("#include ""exports.h""");
            if S.Needs_Stdarg then
               C_Lines.Append ("#include <stdarg.h>");
            end if;
            if S.Needs_Stdlib then
               C_Lines.Append ("#include <stdlib.h>");
            end if;
            if not S.C_Assertions.Is_Empty then
               C_Lines.Append ("");
               C_Lines.Append (S.C_Assertions);
            end if;
            if not S.C_Definitions.Is_Empty then
               C_Lines.Append ("");
               C_Lines.Append (S.C_Definitions);
            end if;
            if not S.C_Functions.Is_Empty then
               declare
                  Definitions : String_Vectors.Vector;
               begin
                  for Each of S.C_Functions loop
                     declare
                        Lines : String_Vectors.Vector;
                     begin
                        Lines.Append
                          (US.To_String (Each.Result) & " "
                           & US.To_String (Each.Name) & "("
                           & (if Each.Parameters.Is_Empty then "void"
                              else T.Join (Each.Parameters, ", ")) & ")");
                        Lines.Append ("{");
                        for Line of Each.Body_Lines loop
                           Lines.Append
                             ((if Line = "" then "" else "    " & Line));
                        end loop;
                        Lines.Append ("}");
                        Definitions.Append (T.Join (Lines, [1 => LF]));
                     end;
                  end loop;
                  C_Lines.Append ("");
                  C_Lines.Append (T.Join (Definitions, Double));
               end;
            end if;
            declare
               Exports : constant String := T.Join (Export_Lines, [1 => LF])
                 & LF;
               Adapters : constant String := T.Join (C_Lines, [1 => LF]) & LF;
               Metadata : constant Meta_Id := T.Object_Meta (S);
               Abi : constant Meta_Id := T.Object_Meta (S);
               Inputs : constant Meta_Id := T.Object_Meta (S);
               Header_List : constant Meta_Id := T.List_Meta (S);
               Define_List : constant Meta_Id := T.List_Meta (S);
               Outputs : constant Meta_Id := T.Object_Meta (S);
               Declarations : constant Meta_Id := T.List_Meta (S);
               Kinds, Ties : String_Vectors.Vector;
            begin
               if T.Contains (Bindings, "import landin/compiler") then
                  Fail (S, "internal: generated forbidden landin/compiler"
                        & " import");
               end if;
               if not T.Contains
                 (Bindings, "compiler.assert(compiler." & Fact_Text & ")")
               then
                  Fail (S, "internal: generated bindings lost the ABI guard");
               end if;
               declare
                  Seen : String_Sets.Set;
               begin
                  for Each of S.C_Functions loop
                     if Seen.Contains (US.To_String (Each.Name)) then
                        Fail (S, "internal: duplicate generated C function");
                     end if;
                     Seen.Include (US.To_String (Each.Name));
                  end loop;
               end;
               Put_Number (S, Metadata, "schema_version", 1);
               Put_Text (S, Metadata, "generator", "landin-bindings/1");
               Put_Text (S, Abi, "target", Triple (S.Chosen));
               Put_Text (S, Abi, "calling_convention", Convention (S.Chosen));
               Put_Text (S, Abi, "data_model", Data_Model (S.Chosen));
               Put_Text (S, Abi, "byte_order", "little");
               Put_Text (S, Abi, "plain_char",
                         (if Unsigned_Char (S.Chosen) then "unsigned"
                          else "signed"));
               Put_Text (S, Abi, "enum_policy",
                         "clang-default-with-fno-short-enums");
               T.Put (S, Metadata, "abi", Abi);
               for Each of S.Headers loop
                  declare
                     Item : constant Meta_Id := T.Object_Meta (S);
                  begin
                     Put_Text (S, Item, "name", US.To_String (Each.Logical));
                     Put_Text (S, Item, "sha256", US.To_String (Each.Digest));
                     T.Append (S, Header_List, Item);
                  end;
               end loop;
               T.Put (S, Inputs, "headers", Header_List);
               Put_Text (S, Inputs, "policy_sha256",
                         US.To_String (S.Policy_Digest));
               for Define of Defines loop
                  declare
                     Item : constant Meta_Id := T.Object_Meta (S);
                     Equal : Natural := 0;
                  begin
                     for Position in Define'Range loop
                        if Define (Position) = '=' then
                           Equal := Position;
                           exit;
                        end if;
                     end loop;
                     Put_Text (S, Item, "name",
                               (if Equal = 0 then Define
                                else Define (Define'First .. Equal - 1)));
                     Put_Text (S, Item, "sha256", GNAT.SHA256.Digest (Define));
                     T.Append (S, Define_List, Item);
                  end;
               end loop;
               T.Put (S, Inputs, "defines", Define_List);
               T.Put (S, Metadata, "inputs", Inputs);
               for Position in 1 .. S.Meta_Declarations.Last_Index loop
                  declare
                     Item : constant Meta_Id :=
                       S.Meta_Declarations (Position);
                     C_Name_Item : constant Meta_Id :=
                       T.Member (S, Item, "c_name");
                  begin
                     Kinds.Append
                       (T.Text_Of (S, T.Member (S, Item, "kind")) & ASCII.NUL
                        & (if T.Kind_Of (S, C_Name_Item) = Meta_Null
                           then "None" else T.Text_Of (S, C_Name_Item))
                        & ASCII.NUL
                        & T.Text_Of (S, T.Member (S, Item, "landin_name")));
                     Ties.Append (Padded (Position));
                  end;
               end loop;
               for Position of Sorted_Order (Kinds, Ties) loop
                  T.Append (S, Declarations,
                            S.Meta_Declarations (Positive'Value (Position)));
               end loop;
               T.Put (S, Metadata, "declarations", Declarations);
               Put_Text (S, Outputs, "bindings.ldn",
                         GNAT.SHA256.Digest (Bindings));
               Put_Text (S, Outputs, "adapters.c",
                         GNAT.SHA256.Digest (Adapters));
               Put_Text (S, Outputs, "exports.h",
                         GNAT.SHA256.Digest (Exports));
               T.Put (S, Metadata, "outputs", Outputs);
               S.Outputs.Clear;
               S.Outputs.Append (Bindings);
               S.Outputs.Append (Adapters);
               S.Outputs.Append (Exports);
               S.Outputs.Append (T.Pretty (S, Metadata));
            end;
         end;
      end;
   end Generate;

end Landin.Bindings.Generation;
