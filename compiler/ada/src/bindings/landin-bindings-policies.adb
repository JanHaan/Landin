with GNAT.SHA256;
with Landin.Bindings.Texts;

package body Landin.Bindings.Policies is

   package T renames Landin.Bindings.Texts;

   function "&" (Left, Right : String_Vectors.Vector)
     return String_Vectors.Vector renames String_Vectors."&";

   function Field (Within : Handle; Item : J.Value; Key : String)
     return J.Value is (J.Member (Within.Policy_Document, Item, Key));

   function Has (Within : Handle; Item : J.Value; Key : String)
     return Boolean is (J.Is_Present (Field (Within, Item, Key)));

   function Is_String (Within : Handle; Item : J.Value) return Boolean is
     (J.Is_Kind (Within.Policy_Document, Item, J.String_Value));

   function Is_Object (Within : Handle; Item : J.Value) return Boolean is
     (J.Is_Kind (Within.Policy_Document, Item, J.Object_Value));

   function Text (Within : Handle; Item : J.Value; Key : String)
     return String
   is
      Value : constant J.Value := Field (Within, Item, Key);
   begin
      return (if Is_String (Within, Value)
              then J.Text (Within.Policy_Document, Value) else "");
   end Text;

   function Is_True (Within : Handle; Item : J.Value; Key : String)
     return Boolean is
     (J.Is_Kind (Within.Policy_Document, Field (Within, Item, Key),
                 J.True_Value));

   function Is_Boolean (Within : Handle; Item : J.Value; Key : String)
     return Boolean is
     (J.Is_Kind (Within.Policy_Document, Field (Within, Item, Key),
                 J.True_Value)
      or else J.Is_Kind (Within.Policy_Document, Field (Within, Item, Key),
                         J.False_Value));

   function Keys (Within : Handle; Item : J.Value)
     return String_Vectors.Vector
   is
      Result : String_Vectors.Vector;
   begin
      if Is_Object (Within, Item) then
         for Position in 1 .. J.Length (Within.Policy_Document, Item) loop
            Result.Append (J.Key (Within.Policy_Document, Item, Position));
         end loop;
      end if;
      return Result;
   end Keys;

   function Elements (Within : Handle; Item : J.Value)
     return Value_Vectors.Vector
   is
      Result : Value_Vectors.Vector;
   begin
      if J.Is_Kind (Within.Policy_Document, Item, J.Array_Value) then
         for Position in 1 .. J.Length (Within.Policy_Document, Item) loop
            Result.Append (J.Element (Within.Policy_Document, Item, Position));
         end loop;
      end if;
      return Result;
   end Elements;

   function Repr (Within : Handle; Item : J.Value) return String is
     (T.Value_Repr (Within.Policy_Document, Item));

   function Kind_Name (Kind : Entry_Kind) return String is
     (case Kind is
         when Alias_Entry => "alias", when Callback_Entry => "callback",
         when Enum_Entry => "enum", when Function_Entry => "function",
         when Incoming_Entry => "incoming_varargs",
         when Record_Entry => "record", when Variable_Entry => "variable");

   function Context (Of_Entry : Policy_Entry) return String is
     ("policy declaration" & Positive'Image (Of_Entry.Index) & " ("
      & Kind_Name (Of_Entry.Kind) & " "
      & T.Repr (US.To_String (Of_Entry.Name)) & ")");

   subtype Name_List is String_Vectors.Vector;

   function Listed (Name : String; Names : Name_List) return Boolean is
     (Names.Contains (Name));

   --  The keys of Item must be exactly Allowed, and Required among them:
   --  the first unknown one, by name, is refused, then the first missing.
   procedure Exact_Keys
     (Within : Handle; Item : J.Value; Allowed : Name_List;
      Context : String;
      Optional : Name_List := String_Vectors.Empty_Vector);

   procedure Exact_Keys
     (Within : Handle; Item : J.Value; Allowed : Name_List;
      Context : String;
      Optional : Name_List := String_Vectors.Empty_Vector)
   is
      Present : constant String_Vectors.Vector := Keys (Within, Item);
      Unknown : String_Sets.Set;
      Missing : String_Sets.Set;
   begin
      for Key of Present loop
         if not Listed (Key, Allowed) and then not Listed (Key, Optional) then
            Unknown.Include (Key);
         end if;
      end loop;
      if not Unknown.Is_Empty then
         Fail (Within, Context & ": unknown key "
           & T.Repr (Unknown.First_Element),
               Policy_Fault);
      end if;
      for Key of Allowed loop
         if not Present.Contains (Key) then
            Missing.Include (Key);
         end if;
      end loop;
      if not Missing.Is_Empty then
         Fail (Within, Context & ": missing required key "
               & T.Repr (Missing.First_Element), Policy_Fault);
      end if;
   end Exact_Keys;

   Promoted_Names : constant Name_List :=
     ["c_int", "c_uint", "c_long", "c_ulong",
      "c_longlong", "c_ulonglong", "c_double", "pointer"];

   --  Python's `== 1`, which true and 1.0 also meet.
   function Is_One (Within : Handle; Item : J.Value) return Boolean;

   function Is_One (Within : Handle; Item : J.Value) return Boolean is
   begin
      if J.Is_Kind (Within.Policy_Document, Item, J.True_Value) then
         return True;
      elsif not J.Is_Kind (Within.Policy_Document, Item, J.Number_Value) then
         return False;
      end if;
      declare
         Written : constant String := J.Text (Within.Policy_Document, Item);
         Index : Positive := Written'First;
      begin
         if Written (Index) /= '1' then
            return False;
         end if;
         Index := Index + 1;
         if Index <= Written'Last and then Written (Index) = '.' then
            Index := Index + 1;
            while Index <= Written'Last and then Written (Index) = '0' loop
               Index := Index + 1;
            end loop;
         end if;
         if Index <= Written'Last and then Written (Index) in 'e' | 'E' then
            Index := Index + 1;
            if Index <= Written'Last and then Written (Index) in '+' | '-' then
               Index := Index + 1;
            end if;
            while Index <= Written'Last and then Written (Index) = '0' loop
               Index := Index + 1;
            end loop;
         end if;
         return Index > Written'Last;
      end;
   end Is_One;

   procedure Validate_Entry
     (Within : Handle; Raw : J.Value; Kind : Entry_Kind;
      Context : String);

   procedure Validate_Entry
     (Within : Handle; Raw : J.Value; Kind : Entry_Kind;
      Context : String)
   is
      Common : constant Name_List :=
        ["kind", "name", "landin_name"];
   begin
      case Kind is
         when Record_Entry =>
            if Text (Within, Raw, "representation")
                 not in "auto" | "native" | "opaque"
              or else not Is_String
                (Within, Field (Within, Raw, "representation"))
            then
               Fail (Within, Context & ": representation must be auto,"
                     & " native, or opaque", Policy_Fault);
            end if;
            if not Is_Object (Within, Field (Within, Raw, "fields")) then
               Fail (Within, Context & ": fields must be an object",
                     Policy_Fault);
            end if;
            Exact_Keys (Within, Raw, ["representation", "fields"],
                        Context, Common);
         when Callback_Entry =>
            if not Is_Boolean (Within, Raw, "nullable") then
               Fail (Within, Context & ": nullable must be Boolean",
                     Policy_Fault);
            end if;
            if not Is_Object (Within, Field (Within, Raw, "parameters")) then
               Fail (Within, Context & ": parameters must be an object,"
                     & " one key per reference parameter's policy; write"
                     & " ""parameters"": {} when none has one", Policy_Fault);
            end if;
            Exact_Keys (Within, Raw, ["nullable", "parameters"],
                        Context, Common & ["result"]);
         when Function_Entry =>
            if not Is_String (Within, Field (Within, Raw, "direction"))
              or else Text (Within, Raw,
                "direction") not in "import" | "export"
            then
               Fail (Within, Context & ": direction must be import or export",
                     Policy_Fault);
            end if;
            if not Is_Object (Within, Field (Within, Raw, "parameters")) then
               Fail (Within, Context & ": parameters must be an object,"
                     & " one key per reference parameter's policy; write"
                     & " ""parameters"": {} when none has one", Policy_Fault);
            end if;
            Exact_Keys (Within, Raw, ["direction", "parameters"],
                        Context, Common & ["result"]);
         when Variable_Entry =>
            if not Is_String (Within, Field (Within, Raw, "storage"))
              or else Text (Within, Raw, "storage") not in "import" | "define"
            then
               Fail (Within, Context & ": storage must be import or define",
                     Policy_Fault);
            end if;
            if not Is_Boolean (Within, Raw, "writable") then
               Fail (Within, Context & ": writable must be Boolean",
                     Policy_Fault);
            end if;
            Exact_Keys (Within, Raw, ["storage", "writable"],
                        Context, Common & ["value"]);
         when Incoming_Entry =>
            if not Is_String (Within, Field (Within, Raw, "handler"))
              or else not Is_C_Identifier (Text (Within, Raw, "handler"))
            then
               Fail (Within, Context & ": handler must be a C identifier",
                     Policy_Fault);
            end if;
            if Is_String (Within, Field (Within, Raw, "name"))
              and then Text (Within, Raw, "handler") = Text (Within, Raw,
                "name")
            then
               Fail (Within, Context & ": handler must differ from the"
                     & " variadic entry name", Policy_Fault);
            end if;
            if not Is_String (Within, Field (Within, Raw, "count_parameter"))
            then
               Fail (Within, Context & ": count_parameter must be a parameter"
                     & " name", Policy_Fault);
            end if;
            if not Is_Object (Within, Field (Within, Raw, "parameters")) then
               Fail (Within, Context & ": parameters must be an object,"
                     & " one key per reference parameter's policy; write"
                     & " ""parameters"": {} when none has one", Policy_Fault);
            end if;
            declare
               Schema : constant J.Value := Field (Within, Raw, "schema");
               Seen : String_Sets.Set;
            begin
               if not J.Is_Kind (Within.Policy_Document, Schema, J.Array_Value)
                 or else J.Length (Within.Policy_Document, Schema) = 0
               then
                  Fail (Within, Context & ": schema must be a nonempty array",
                        Policy_Fault);
               end if;
               for At_Item in 1 .. J.Length (Within.Policy_Document, Schema)
               loop
                  declare
                     Item : constant J.Value :=
                       J.Element (Within.Policy_Document, Schema, At_Item);
                     Item_Context : constant String :=
                       Context & " schema item" & Positive'Image (At_Item);
                     Pointer : constant Boolean :=
                       Is_String (Within, Field (Within, Item, "promoted"))
                       and then Text (Within, Item, "promoted") = "pointer";
                  begin
                     if not Is_Object (Within, Item) then
                        Fail (Within, Item_Context & ": must be an object",
                              Policy_Fault);
                     end if;
                     if Pointer then
                        Exact_Keys
                          (Within, Item,
                           ["name", "promoted", "policy"],
                           Item_Context);
                     else
                        Exact_Keys
                          (Within, Item, ["name", "promoted"],
                           Item_Context);
                     end if;
                     declare
                        Tail_Name : constant String :=
                          Text (Within, Item, "name");
                     begin
                        if not Is_String (Within, Field (Within, Item, "name"))
                          or else not Is_C_Identifier (Tail_Name)
                        then
                           Fail (Within, Item_Context
                                 & ": name must be a C identifier",
                                 Policy_Fault);
                        end if;
                        if Seen.Contains (Tail_Name) then
                           Fail (Within, Item_Context & ": duplicate name "
                                 & T.Repr (Tail_Name), Policy_Fault);
                        end if;
                        Seen.Include (Tail_Name);
                     end;
                     if not Is_String (Within, Field (Within, Item,
                       "promoted"))
                       or else not Listed
                         (Text (Within, Item, "promoted"), Promoted_Names)
                     then
                        Fail (Within, Item_Context
                              & ": unsupported promoted type "
                              & Repr (Within, Field (Within, Item,
                                "promoted")),
                              Policy_Fault);
                     end if;
                  end;
               end loop;
            end;
            Exact_Keys
              (Within, Raw,
               ["handler", "count_parameter", "schema",
                "parameters"],
               Context, Common & ["result"]);
         when Alias_Entry | Enum_Entry =>
            Exact_Keys (Within, Raw, [], Context, Common);
      end case;
   end Validate_Entry;

   --  The key a duplicate-key refusal at Offset names.
   function Key_At (Text : String; Offset : Natural) return String;

   function Key_At (Text : String; Offset : Natural) return String is
      First : constant Positive := Text'First + Offset + 1;
      Last : Natural := First - 1;
   begin
      while Last + 1 <= Text'Last and then Text (Last + 1) /= '"' loop
         Last := Last + 1;
      end loop;
      return Text (First .. Last);
   end Key_At;

   procedure Load (Within : Handle; Text : String) is
      Doc : J.Document renames Within.Policy_Document;
   begin
      J.Parse (Doc, Text);
      if not J.Ok (Doc) then
         if J.Fault (Doc) = "a member is named twice" then
            Fail (Within, "policy: duplicate JSON key "
                  & T.Repr (Key_At (Text, J.Fault_At (Doc))), Policy_Fault);
         end if;
         Fail (Within, "policy is not valid UTF-8 JSON: " & J.Fault (Doc)
               & " at byte" & Natural'Image (J.Fault_At (Doc)),
               Policy_Fault);
      end if;
      declare
         Data : constant J.Value := J.Root (Doc);
      begin
         if not Is_Object (Within, Data) then
            Fail (Within, "policy: top level must be an object", Policy_Fault);
         end if;
         Exact_Keys
           (Within, Data,
            ["schema_version", "namespace", "abi",
             "declarations"], "policy");
         if not Is_One (Within, Field (Within, Data, "schema_version")) then
            Fail (Within, "policy: schema_version must be 1", Policy_Fault);
         end if;
         if not Is_String (Within, Field (Within, Data, "namespace"))
           or else not Is_C_Identifier (Policies.Text (Within, Data,
             "namespace"))
         then
            Fail (Within, "policy: namespace must be a C identifier",
                  Policy_Fault);
         end if;
         Within.Namespace := US.To_Unbounded_String
           (Policies.Text (Within, Data, "namespace"));
         declare
            Abi : constant J.Value := Field (Within, Data, "abi");
            Found : Boolean := False;
         begin
            if not Is_Object (Within, Abi) then
               Fail (Within, "policy: abi must be an object", Policy_Fault);
            end if;
            Exact_Keys
              (Within, Abi,
               ["target", "data_model", "plain_char",
                "enum_policy"], "policy abi",
               Optional => ["calling_convention"]);
            if Is_String (Within, Field (Within, Abi, "target")) then
               for Each in Target loop
                  if Triple (Each) = Policies.Text (Within, Abi, "target") then
                     Within.Chosen := Each;
                     Found := True;
                  end if;
               end loop;
            end if;
            if not Found then
               declare
                  Known : US.Unbounded_String;
               begin
                  for Each in Target loop
                     US.Append (Known, (if Each = Target'First then ""
                                        elsif Each = Target'Last then " or "
                                        else ", ")
                                       & T.Repr (Triple (Each)));
                  end loop;
                  Fail (Within, "policy abi: unsupported target "
                        & Repr (Within, Field (Within, Abi, "target"))
                        & "; name one of the triples Clang prints for"
                        & " refine's targets: " & US.To_String (Known),
                        Policy_Fault);
               end;
            end if;
            Within.Target_Triple := US.To_Unbounded_String
              (Triple (Within.Chosen));
            declare
               procedure Expect (Key, Value : String);

               procedure Expect (Key, Value : String) is
               begin
                  if not Is_String (Within, Field (Within, Abi, Key))
                    or else Policies.Text (Within, Abi, Key) /= Value
                  then
                     Fail (Within, "policy abi: " & Key & " must be "
                           & T.Repr (Value) & ", got "
                           & Repr (Within, Field (Within, Abi, Key)),
                           Policy_Fault);
                  end if;
               end Expect;
            begin
               --  D935: where one refine target has two conventions, the
               --  policy names the one it binds for as well as its
               --  triple, so the VFP variant is never chosen by a suffix
               --  alone.
               if Has (Within, Abi, "calling_convention")
                 or else (for some Each in Target =>
                            Each /= Within.Chosen
                            and then Target_Name (Each)
                                     = Target_Name (Within.Chosen))
               then
                  if not Has (Within, Abi, "calling_convention") then
                     Fail (Within, "policy abi: missing required key"
                           & " 'calling_convention', which says which of "
                           & Target_Name (Within.Chosen) & "'s conventions"
                           & " the policy binds for: "
                           & T.Repr (Convention (Within.Chosen))
                           & " for " & T.Repr (Triple (Within.Chosen)),
                           Policy_Fault);
                  end if;
                  Expect ("calling_convention", Convention (Within.Chosen));
               end if;
               Expect ("data_model", Data_Model (Within.Chosen));
               Expect ("plain_char",
                       (if Unsigned_Char (Within.Chosen) then "unsigned"
                        else "signed"));
               Expect ("enum_policy", "clang-default");
            end;
         end;
         declare
            Raw_Entries : constant J.Value :=
              Field (Within, Data, "declarations");
            Seen : String_Sets.Set;
         begin
            if not J.Is_Kind (Doc, Raw_Entries, J.Array_Value)
              or else J.Length (Doc, Raw_Entries) = 0
            then
               Fail (Within, "policy: declarations must be a nonempty array",
                     Policy_Fault);
            end if;
            for Index in 1 .. J.Length (Doc, Raw_Entries) loop
               declare
                  Raw : constant J.Value :=
                    J.Element (Doc, Raw_Entries, Index);
                  Number : constant String :=
                    "policy declaration" & Positive'Image (Index);
                  Kind : Entry_Kind := Alias_Entry;
                  Known : Boolean := False;
               begin
                  if not Is_Object (Within, Raw) then
                     Fail (Within, Number & ": must be an object",
                           Policy_Fault);
                  end if;
                  if Is_String (Within, Field (Within, Raw, "kind")) then
                     for Each in Entry_Kind loop
                        if Kind_Name (Each) = Policies.Text (Within, Raw,
                          "kind")
                        then
                           Kind := Each;
                           Known := True;
                        end if;
                     end loop;
                  end if;
                  if not Known then
                     Fail (Within, Number & ": unknown kind "
                           & Repr (Within, Field (Within, Raw, "kind")),
                           Policy_Fault);
                  end if;
                  if not Is_String (Within, Field (Within, Raw, "name"))
                    or else Policies.Text (Within, Raw, "name") = ""
                  then
                     Fail (Within, Number
                           & ": name must be a nonempty string", Policy_Fault);
                  end if;
                  declare
                     Name : constant String :=
                       Policies.Text (Within, Raw, "name");
                     Context : constant String :=
                       Number & " (" & Kind_Name (Kind) & " " & T.Repr (Name)
                       & ")";
                     Key : constant String := Kind_Name (Kind) & " " & Name;
                     Landin_Name : US.Unbounded_String;
                  begin
                     if (for all Char of Name => Char = '@'
                       or else T.Is_Space (Char))
                     then
                        Fail (Within, Context & ": name must contain a"
                              & " non-whitespace, non-@ character",
                              Policy_Fault);
                     end if;
                     if Seen.Contains (Key) then
                        Fail (Within, Number & ": duplicate selection "
                              & Kind_Name (Kind) & " " & T.Repr (Name),
                              Policy_Fault);
                     end if;
                     Seen.Include (Key);
                     if Has (Within, Raw, "landin_name") then
                        if not Is_String
                          (Within, Field (Within, Raw, "landin_name"))
                          or else not T.Is_Landin_Identifier
                            (Policies.Text (Within, Raw, "landin_name"))
                        then
                           Fail (Within, Context
                                 & ": landin_name must be an identifier",
                                 Policy_Fault);
                        end if;
                        Landin_Name := US.To_Unbounded_String
                          (Policies.Text (Within, Raw, "landin_name"));
                     else
                        declare
                           First : Positive := Name'First;
                        begin
                           while Name (First) = '@' loop
                              First := First + 1;
                           end loop;
                           Landin_Name := US.To_Unbounded_String
                             (T.Sanitize_Landin
                                (T.Words (Name (First .. Name'Last))
                                 .Last_Element));
                        end;
                     end if;
                     if US.To_String (Landin_Name) = "_"
                       or else T.Is_Avoided (US.To_String (Landin_Name))
                     then
                        Fail (Within, Context & ": landin_name "
                              & T.Repr (US.To_String (Landin_Name))
                              & " is reserved", Policy_Fault);
                     end if;
                     Validate_Entry (Within, Raw, Kind, Context);
                     Within.Entries.Append
                       (Policy_Entry'
                          (Kind => Kind,
                         Name => US.To_Unbounded_String (Name),
                         Landin_Name => Landin_Name,
                         Raw => Raw, Index => Index));
                  end;
               end;
            end loop;
         end;
      end;
      Within.Policy_Digest := US.To_Unbounded_String
        (GNAT.SHA256.Digest (Text));
   end Load;

   function Annotation_Of
     (Within : Handle; Item : J.Value; Context : String)
      return Annotation
   is
      Result : Annotation;
   begin
      if not Is_Object (Within, Item) then
         Fail (Within, Context & ": pointer policy must be an object");
      end if;
      declare
         Expected : constant Name_List :=
           ["ownership", "nullability", "from", "retention"];
         Present : constant String_Vectors.Vector := Keys (Within, Item);
         Unknown, Missing : String_Sets.Set;
      begin
         for Key of Present loop
            if not Listed (Key, Expected) then
               Unknown.Include (Key);
            end if;
         end loop;
         for Key of Expected loop
            if not Present.Contains (Key) then
               Missing.Include (Key);
            end if;
         end loop;
         if not Unknown.Is_Empty then
            Fail (Within, Context & ": unknown pointer-policy key "
                  & T.Repr (Unknown.First_Element));
         end if;
         if not Missing.Is_Empty then
            Fail (Within, Context & ": missing pointer-policy key "
                  & T.Repr (Missing.First_Element));
         end if;
      end;
      if not Is_String (Within, Field (Within, Item, "ownership"))
        or else Text (Within, Item, "ownership")
                not in "borrowed" | "caller_owned" | "c_owned" | "static"
                     | "transferred"
      then
         Fail (Within, Context & ": unsupported ownership "
               & Repr (Within, Field (Within, Item, "ownership")));
      end if;
      if not Is_String (Within, Field (Within, Item, "nullability"))
        or else Text (Within, Item, "nullability")
                not in "nonnullable" | "nullable"
      then
         Fail (Within, Context
               & ": nullability must be nonnullable or nullable");
      end if;
      if not Is_String (Within, Field (Within, Item, "retention"))
        or else Text (Within, Item, "retention")
                not in "call" | "returned" | "static" | "stored"
      then
         Fail (Within, Context & ": unsupported retention "
               & Repr (Within, Field (Within, Item, "retention")));
      end if;
      declare
         Sources : constant J.Value := Field (Within, Item, "from");
         Seen : String_Sets.Set;
      begin
         if not J.Is_Kind (Within.Policy_Document, Sources, J.Array_Value)
           or else (for some Source of Elements (Within, Sources) =>
                      not Is_String (Within, Source)
                      or else not Is_C_Identifier
                        (J.Text (Within.Policy_Document, Source)))
         then
            Fail (Within, Context
                  & ": from must be an array of parameter names");
         end if;
         for Source of Elements (Within, Sources) loop
            declare
               Name : constant String :=
                 J.Text (Within.Policy_Document, Source);
            begin
               if Seen.Contains (Name) then
                  Fail (Within, Context & ": from names must be unique");
               end if;
               Seen.Include (Name);
               Result.From.Append (Name);
            end;
         end loop;
      end;
      Result.Present := True;
      Result.Ownership := US.To_Unbounded_String
        (Text (Within, Item, "ownership"));
      Result.Nullability := US.To_Unbounded_String
        (Text (Within, Item, "nullability"));
      Result.Retention := US.To_Unbounded_String
        (Text (Within, Item, "retention"));
      return Result;
   end Annotation_Of;

end Landin.Bindings.Policies;
