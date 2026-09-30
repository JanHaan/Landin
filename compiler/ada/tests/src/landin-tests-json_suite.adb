--  The JSON reader and writer a server talks through.
--
--  Every refusal the reader promises is asked for by name, every escape is
--  decoded and written back, and a seeded run of hostile bytes -- random,
--  and the corpus of valid documents with one byte changed -- must never
--  raise: an editor that sends garbage is answered, not obeyed and not
--  crashed on.

with Interfaces;

with Landin.Json;

package body Landin.Tests.Json_Suite is

   package J renames Landin.Json;

   use type J.Value_Kind;
   use type J.Integer_Value;

   LF : constant Character := ASCII.LF;

   function Refusal (Text : String) return String;

   --  The fault a text is refused with, or "" when it parses.
   function Refusal (Text : String) return String is
      Document : J.Document;
   begin
      J.Parse (Document, Text);
      return (if J.Ok (Document) then "" else J.Fault (Document));
   end Refusal;

   function Canonical (Text : String) return String;

   --  A text parsed and written back.
   function Canonical (Text : String) return String is
      Document : J.Document;
      Written  : J.Builder;
   begin
      J.Parse (Document, Text);
      if not J.Ok (Document) then
         return "refused: " & J.Fault (Document);
      end if;
      J.Copy (Written, Document, J.Root (Document));
      return J.Result (Written);
   end Canonical;

   procedure Every_Value_Is_Read
     (Item : in out Landin.Testing.Context);

   procedure Every_Value_Is_Read
     (Item : in out Landin.Testing.Context)
   is
      Document : J.Document;
      Text : constant String :=
        " { ""id"" : -12, ""ok"": true, ""no"": false, ""x"": null,"
        & " ""list"": [1, 2.5, ""a""], ""empty"": {}, ""none"": [] }"
        & LF;
   begin
      J.Parse (Document, Text);
      Landin.Testing.Check (Item, J.Ok (Document), "the document is read");
      declare
         Root : constant J.Value := J.Root (Document);
         List : constant J.Value := J.Member (Document, Root, "list");
      begin
         Landin.Testing.Check_Equal
           (Item, J.Length (Document, Root), 7, "an object's members");
         Landin.Testing.Check
           (Item, J.Integer_Of (Document, J.Member (Document, Root, "id"))
                  = -12,
            "a negative integer");
         Landin.Testing.Check
           (Item, J.Is_Kind
              (Document, J.Member (Document, Root, "ok"), J.True_Value)
            and then J.Is_Kind
              (Document, J.Member (Document, Root, "no"), J.False_Value)
            and then J.Is_Kind
              (Document, J.Member (Document, Root, "x"), J.Null_Value),
            "the three words");
         Landin.Testing.Check
           (Item, not J.Is_Integer (Document, J.Element (Document, List, 2)),
            "a fraction is a number and not an integer");
         Landin.Testing.Check_Equal
           (Item, J.Text (Document, J.Element (Document, List, 2)), "2.5",
            "a number keeps its text");
         Landin.Testing.Check_Equal
           (Item, J.Text (Document, J.Element (Document, List, 3)), "a",
            "a string element");
         Landin.Testing.Check
           (Item, not J.Is_Present (J.Member (Document, Root, "absent"))
                  and then not J.Is_Present
                    (J.Member (Document, List, "a")),
            "an absent member, and a member asked of an array, are absent");
         Landin.Testing.Check_Equal
           (Item, J.Key (Document, Root, 5), "list", "keys keep their order");
      end;
   end Every_Value_Is_Read;

   procedure Every_Refusal_Is_Named
     (Item : in out Landin.Testing.Context);

   procedure Every_Refusal_Is_Named
     (Item : in out Landin.Testing.Context)
   is
      procedure Refused (Text : String; Reason : String);

      procedure Refused (Text : String; Reason : String) is
      begin
         Landin.Testing.Check_Equal (Item, Refusal (Text), Reason, Text);
      end Refused;

      Deep : constant String := [1 .. J.Maximum_Depth + 1 => '['];
      Just : constant String :=
        [1 .. J.Maximum_Depth => '['] & [1 .. J.Maximum_Depth => ']'];
   begin
      Refused ("", "a value is missing");
      Refused ("  ", "a value is missing");
      Refused ("nul", "not a JSON value");
      Refused ("'a'", "not a JSON value");
      Refused ("1 2", "text follows the value");
      Refused ("{} x", "text follows the value");
      Refused ("[1,]", "not a JSON value");
      Refused ("[1 2]", "expected ',' or ']'");
      Refused ("[1", "an array is not closed");
      Refused ("{""a"":1", "an object is not closed");
      Refused ("{1:2}", "a member needs a string name");
      Refused ("{""a"" 1}", "a member name needs a ':'");
      Refused ("{""a"":1,""a"":2}", "a member is named twice");
      Refused ("""abc", "a string is not closed");
      Refused ("""a" & ASCII.HT & """", "a control character must be escaped");
      Refused ("""\x""", "not an escape JSON has");
      Refused ("""\u12""", "a \u escape needs four hexadecimal digits");
      Refused ("""\u12g4""", "a \u escape needs four hexadecimal digits");
      Refused ("""\ud800""", "a high surrogate stands alone");
      Refused ("""\ud800A""", "a high surrogate stands alone");
      Refused ("""\udc00""", "a low surrogate stands alone");
      Refused ("""" & Character'Val (16#C0#) & Character'Val (16#80#)
               & """", "not UTF-8");
      Refused ("""" & Character'Val (16#ED#) & Character'Val (16#A0#)
               & Character'Val (16#80#) & """", "not UTF-8");
      Refused ("""" & Character'Val (16#F4#) & Character'Val (16#90#)
               & Character'Val (16#80#) & Character'Val (16#80#) & """",
               "not UTF-8");
      Refused ("""" & Character'Val (16#E2#) & """", "not UTF-8");
      Refused ("01", "text follows the value");
      Refused ("-", "a number needs a digit here");
      Refused ("1.", "a number needs a digit here");
      Refused ("1e", "a number needs a digit here");
      Refused ("+1", "not a JSON value");
      Refused (Deep, "nested deeper than 64");
      Landin.Testing.Check_Equal
        (Item, Refusal (Just), "", "exactly the deepest nesting is read");

      declare
         Document : J.Document;
      begin
         J.Parse (Document, "[1, 2, x]");
         Landin.Testing.Check_Equal
           (Item, J.Fault_At (Document), 7, "a fault says where it is");
      end;
   end Every_Refusal_Is_Named;

   procedure Integers_Are_Exact
     (Item : in out Landin.Testing.Context);

   procedure Integers_Are_Exact
     (Item : in out Landin.Testing.Context)
   is
      function Integral (Text : String) return Boolean;

      function Integral (Text : String) return Boolean is
         Document : J.Document;
      begin
         J.Parse (Document, Text);
         return J.Ok (Document)
           and then J.Is_Integer (Document, J.Root (Document));
      end Integral;

      Document : J.Document;
   begin
      Landin.Testing.Check
        (Item, Integral ("9007199254740991")
               and then Integral ("-9007199254740991")
               and then Integral ("0") and then Integral ("-0"),
         "every integer within 2**53 - 1 is one");
      Landin.Testing.Check
        (Item, not Integral ("9007199254740992")
               and then not Integral ("99999999999999999999999999")
               and then not Integral ("1e3") and then not Integral ("1.0"),
         "past 2**53 - 1, or written with a fraction or exponent, is not");
      J.Parse (Document, "9007199254740991");
      Landin.Testing.Check
        (Item, J.Integer_Of (Document, J.Root (Document))
               = J.Integer_Value (J.Largest_Integer),
         "the largest is read exactly");
      Landin.Testing.Check_Equal
        (Item, Canonical ("1E+999"), "1E+999",
         "a number no integer holds is kept as written");
   end Integers_Are_Exact;

   procedure Strings_Round_Trip
     (Item : in out Landin.Testing.Context);

   procedure Strings_Round_Trip
     (Item : in out Landin.Testing.Context)
   is
      Document : J.Document;
      E_Acute : constant String :=
        Character'Val (16#C3#) & Character'Val (16#A9#);
      Clef : constant String :=
        Character'Val (16#F0#) & Character'Val (16#9D#)
        & Character'Val (16#84#) & Character'Val (16#9E#);
   begin
      J.Parse (Document, """a\""\\\/\b\f\n\r\t\u00e9\ud834\udd1e\u0001""");
      Landin.Testing.Check_Equal
        (Item, J.Text (Document, J.Root (Document)),
         "a""\/" & ASCII.BS & ASCII.FF & ASCII.LF & ASCII.CR & ASCII.HT
         & E_Acute & Clef & Character'Val (1),
         "every escape is decoded to UTF-8");
      Landin.Testing.Check_Equal
        (Item, J.Quoted (J.Text (Document, J.Root (Document))),
         """a\""\\/\b\f\n\r\t" & E_Acute & Clef & "\u0001""",
         "and written back with only what must be escaped");
      Landin.Testing.Check_Equal
        (Item, J.Quoted ("x" & Character'Val (16#FF#) & "y"
                         & Character'Val (16#C3#)),
         """x\ufffdy\ufffd""",
         "a byte that is not UTF-8 is written as U+FFFD");
      Landin.Testing.Check_Equal
        (Item,
         Canonical (" { ""b"" : [ 1 , { } , [ ] ] , ""a"" : ""A"" } "),
         "{""b"":[1,{},[]],""a"":""A""}",
         "a document is written back canonically, in its own order");
   end Strings_Round_Trip;

   procedure The_Builder_Places_Commas
     (Item : in out Landin.Testing.Context);

   procedure The_Builder_Places_Commas
     (Item : in out Landin.Testing.Context)
   is
      Written : J.Builder;
   begin
      J.Begin_Object (Written);
      J.Name (Written, "jsonrpc");
      J.Write_String (Written, "2.0");
      J.Name (Written, "id");
      J.Write_Integer (Written, -3);
      J.Name (Written, "result");
      J.Begin_Array (Written);
      J.Write_Null (Written);
      J.Write_Boolean (Written, True);
      J.Begin_Object (Written);
      J.End_Object (Written);
      J.Write_Raw (Written, "[1]");
      J.End_Array (Written);
      J.End_Object (Written);
      Landin.Testing.Check_Equal
        (Item, J.Result (Written),
         "{""jsonrpc"":""2.0"",""id"":-3,""result"":[null,true,{},[1]]}",
         "members and elements are separated once each");
   end The_Builder_Places_Commas;

   --  Hostile bytes never raise.  The seeds are fixed, so a failure names
   --  the input that found it; the generator is splitmix64, the same one
   --  the fuzz lane uses, so a seed means one input on every host.
   procedure Hostile_Bytes_Never_Raise
     (Item : in out Landin.Testing.Context);

   procedure Hostile_Bytes_Never_Raise
     (Item : in out Landin.Testing.Context)
   is
      use type Interfaces.Unsigned_64;

      State : Interfaces.Unsigned_64 := 16#4C_414E_4449_4E#;

      function Next return Interfaces.Unsigned_64;

      function Next return Interfaces.Unsigned_64 is
         Z : Interfaces.Unsigned_64;
      begin
         State := State + 16#9E37_79B9_7F4A_7C15#;
         Z := State;
         Z := (Z xor Interfaces.Shift_Right (Z, 30)) * 16#BF58_476D_1CE4_E5B9#;
         Z := (Z xor Interfaces.Shift_Right (Z, 27)) * 16#94D0_49BB_1331_11EB#;
         return Z xor Interfaces.Shift_Right (Z, 31);
      end Next;

      function Below (Bound : Positive) return Natural
        is (Natural (Next mod Interfaces.Unsigned_64 (Bound)));

      function Seed_Text (Index : Positive) return String
        is (case Index is
              when 1 =>
                "{""jsonrpc"":""2.0"",""id"":1,""method"":""initialize"","
                & """params"":{""capabilities"":{}}}",
              when 2 => "[1,-2.5e3,true,false,null,""\u00e9\ud834\udd1e""]",
              when 3 => "{""a"":{""b"":{""c"":[[[[[]]]]]}}}",
              when others => """\n\t\\\"" x""");

      Alphabet : constant String := "{}[]"",:\/-+.0123456789eEtrufalsn "
        & ASCII.LF & ASCII.HT;
      Survived : Natural := 0;
   begin
      for Round in 1 .. 4_000 loop
         declare
            Length : constant Natural := Below (48);
            Text   : String (1 .. Length);
            Seed   : constant String := Seed_Text (Round mod 4 + 1);
            Mutant : String := Seed;
         begin
            for Index in Text'Range loop
               Text (Index) :=
                 (if Below (4) = 0 then Character'Val (Below (256))
                  else Alphabet (Alphabet'First + Below (Alphabet'Length)));
            end loop;
            Mutant (Mutant'First + Below (Mutant'Length)) :=
              Character'Val (Below (256));
            declare
               Document : J.Document;
               Written  : J.Builder;
            begin
               J.Parse (Document, Text);
               J.Parse (Document, Mutant);
               if J.Ok (Document) then
                  J.Copy (Written, Document, J.Root (Document));
                  --  What the writer made is JSON the reader accepts.
                  J.Parse (Document, J.Result (Written));
                  if not J.Ok (Document) then
                     Landin.Testing.Fail
                       (Item, "a written document is refused: "
                              & J.Result (Written));
                  end if;
               end if;
               Survived := Survived + 1;
            exception
               when others =>
                  Landin.Testing.Fail
                    (Item, "round" & Natural'Image (Round) & " raised");
            end;
         end;
      end loop;
      Landin.Testing.Check_Equal
        (Item, Survived, 4_000, "every hostile input was answered");
   end Hostile_Bytes_Never_Raise;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "json", "every value is read", Every_Value_Is_Read'Access);
      Landin.Testing.Register
        (Into, "json", "every refusal is named",
         Every_Refusal_Is_Named'Access);
      Landin.Testing.Register
        (Into, "json", "integers are exact", Integers_Are_Exact'Access);
      Landin.Testing.Register
        (Into, "json", "strings round trip", Strings_Round_Trip'Access);
      Landin.Testing.Register
        (Into, "json", "the builder places commas",
         The_Builder_Places_Commas'Access);
      Landin.Testing.Register
        (Into, "json", "hostile bytes never raise",
         Hostile_Bytes_Never_Raise'Access);
   end Register;

end Landin.Tests.Json_Suite;
