--  The XML reader a device's SVD is read through (D555).
--
--  What it reads is asked for element by element, every reference and
--  section it decodes is decoded, every refusal it promises is asked for
--  with the line and column it names, and a seeded run of hostile bytes --
--  random, and a valid document with bytes changed -- must never raise: a
--  vendor's file that is not XML is answered, not obeyed and not crashed
--  on.

with Interfaces;

with Landin.Xml;

package body Landin.Tests.Xml_Suite is

   package X renames Landin.Xml;

   LF : constant Character := ASCII.LF;
   CR : constant Character := ASCII.CR;

   function Image (Value : Integer) return String;

   function Image (Value : Integer) return String is
      Text : constant String := Integer'Image (Value);
   begin
      return (if Value < 0 then Text else Text (Text'First + 1 .. Text'Last));
   end Image;

   --  The fault a text is refused with and where, or "" when it parses.
   function Refusal (Text : String) return String;

   function Refusal (Text : String) return String is
      Document : X.Document;
   begin
      X.Parse (Document, Text);
      if X.Ok (Document) then
         return "";
      end if;
      return Image (X.Fault_Line (Document)) & ":"
        & Image (X.Fault_Column (Document)) & ": " & X.Fault (Document);
   end Refusal;

   Device : constant String :=
     "<?xml version=""1.0"" encoding=""utf-8"" standalone=""no""?>" & LF
     & "<!-- Copyright the vendor. -->" & LF
     & "<device schemaVersion=""1.1"" xmlns:xs='http://x'>" & LF
     & "  <name>RP2040</name>" & LF
     & "  <peripherals>" & LF
     & "    <peripheral derivedFrom=""UART0"">" & LF
     & "      <name>UART1</name>" & LF
     & "      <baseAddress>0x40038000</baseAddress>" & LF
     & "    </peripheral>" & LF
     & "    <peripheral><name>UART0</name><registers/></peripheral>" & LF
     & "  </peripherals>" & LF
     & "</device>" & LF
     & "<!-- trailing -->" & LF;

   procedure Elements_Are_Read (Item : in out Landin.Testing.Context);

   procedure Elements_Are_Read (Item : in out Landin.Testing.Context) is
      Document : X.Document;
   begin
      X.Parse (Document, Device);
      Landin.Testing.Check (Item, X.Ok (Document), "the document is read");
      if not X.Ok (Document) then
         Landin.Testing.Fail (Item, X.Fault (Document));
         return;
      end if;
      declare
         Root : constant X.Element := X.Root (Document);
         Peripherals : constant X.Element :=
           X.Child (Document, Root, "peripherals");
         First : constant X.Element :=
           X.First_Child (Document, Peripherals);
         Second : constant X.Element := X.Next_Sibling (Document, First);
      begin
         Landin.Testing.Check_Equal
           (Item, X.Name (Document, Root), "device", "the root's name");
         Landin.Testing.Check_Equal
           (Item, X.Attribute_Count (Document, Root), 2,
            "the root's attributes");
         Landin.Testing.Check_Equal
           (Item, X.Attribute_Name (Document, Root, 2), "xmlns:xs",
            "a prefixed attribute name");
         Landin.Testing.Check_Equal
           (Item, X.Attribute (Document, Root, "xmlns:xs"), "http://x",
            "a single-quoted value");
         Landin.Testing.Check_Equal
           (Item, X.Text (Document, X.Child (Document, Root, "name")),
            "RP2040", "an element's text");
         Landin.Testing.Check_Equal
           (Item, X.Child_Count (Document, Peripherals, "peripheral"), 2,
            "children are counted by name");
         Landin.Testing.Check_Equal
           (Item, X.Attribute (Document, First, "derivedFrom"), "UART0",
            "an attribute by name");
         Landin.Testing.Check
           (Item, not X.Has_Attribute (Document, Second, "derivedFrom")
            and then X.Attribute (Document, Second, "derivedFrom") = "",
            "an absent attribute");
         Landin.Testing.Check_Equal
           (Item, X.Text (Document,
                          X.Child (Document, First, "baseAddress")),
            "0x40038000", "a nested element's text");
         Landin.Testing.Check
           (Item, X.Is_Present (X.Child (Document, Second, "registers"))
            and then not X.Is_Present
              (X.First_Child
                 (Document, X.Child (Document, Second, "registers"))),
            "an empty element");
         Landin.Testing.Check
           (Item, not X.Is_Present (X.Next_Sibling (Document, Second)),
            "the last child has no sibling");
         Landin.Testing.Check
           (Item, not X.Is_Present (X.Child (Document, Root, "cpu")),
            "an absent child");
         Landin.Testing.Check_Equal
           (Item, X.Line (Document, First), 6, "an element's line");
         Landin.Testing.Check_Equal
           (Item, X.Column (Document, First), 5, "an element's column");
         Landin.Testing.Check_Equal
           (Item, X.Text (Document, Root)'Length, 7,
            "a parent's own text is the space between its children");
      end;
   end Elements_Are_Read;

   procedure References_Are_Decoded (Item : in out Landin.Testing.Context);

   procedure References_Are_Decoded (Item : in out Landin.Testing.Context)
   is
      Document : X.Document;
      Smile : constant String :=
        [Character'Val (16#E2#), Character'Val (16#98#),
         Character'Val (16#BA#)];
   begin
      X.Parse
        (Document,
         "<a note=""x&amp;y&#9;" & LF & "z&quot;"">&lt;&gt;&amp;&apos;"
         & "&quot;&#65;&#x263A;<![CDATA[<b>&amp;]]>" & CR & LF & "end"
         & CR & "</a>");
      Landin.Testing.Check (Item, X.Ok (Document), "the document is read");
      if not X.Ok (Document) then
         Landin.Testing.Fail (Item, X.Fault (Document));
         return;
      end if;
      Landin.Testing.Check_Equal
        (Item, X.Text (Document, X.Root (Document)),
         "<>&'""A" & Smile & "<b>&amp;" & LF & "end" & LF,
         "references, a CDATA section and line ends");
      Landin.Testing.Check_Equal
        (Item, X.Attribute (Document, X.Root (Document), "note"),
         "x&y" & ASCII.HT & " z""",
         "an attribute value's references and space");
      X.Parse (Document, [Character'Val (16#EF#), Character'Val (16#BB#),
                          Character'Val (16#BF#)] & "<a>" & Smile & "</a>");
      Landin.Testing.Check
        (Item, X.Ok (Document)
         and then X.Text (Document, X.Root (Document)) = Smile,
         "a byte order mark and UTF-8 text");
      X.Parse (Document, "<?pi data?><a><?other?>x<!-- c --></a>");
      Landin.Testing.Check
        (Item, X.Ok (Document)
         and then X.Text (Document, X.Root (Document)) = "x",
         "instructions and comments are skipped");
   end References_Are_Decoded;

   procedure Every_Refusal_Is_Placed (Item : in out Landin.Testing.Context);

   procedure Every_Refusal_Is_Placed (Item : in out Landin.Testing.Context)
   is
      procedure Expect (Text, Expected : String);

      procedure Expect (Text, Expected : String) is
         Actual : constant String := Refusal (Text);
      begin
         Landin.Testing.Check_Equal
           (Item, Actual (Actual'First ..
                    Actual'First
                    + Natural'Min (Actual'Length, Expected'Length) - 1),
            Expected, "refused: " & Text);
      end Expect;
   begin
      Expect ("", "1:1: the document has no root element");
      Expect ("  " & LF & "text", "2:1: the root element was expected");
      Expect ("<a>" & LF & "  <b></a>",
              "2:6: </a> does not close <b>, open since line 2, column 3");
      Expect ("<a><b>", "1:4: <b> is not closed before the document ends");
      Expect ("<a x='1' x='2'/>", "1:10: the attribute x is given twice");
      Expect ("<a x='<'/>", "1:7: < in an attribute value");
      Expect ("<a x=1/>", "1:6: a quoted value was expected");
      Expect ("<a x='1'y='2'/>", "1:9: > or /> was expected");
      Expect ("<a>]]></a>", "1:4: ]]> in character data");
      Expect ("<a>&nbsp;</a>", "1:4: the entity &nbsp; is not one of");
      Expect ("<a>& b</a>", "1:4: `&` begins no reference");
      Expect ("<a>&#xD800;</a>", "1:4: a character reference names a");
      Expect ("<a>&#12a;</a>", "1:4: a decimal character reference");
      Expect ("<a>&#1-;</a>", "1:4: a character reference holds");
      Expect ("<a>&#x;</a>", "1:4: a character reference is not ended");
      Expect ("<a><!-- a -- b --></a>", "1:11: -- inside a comment");
      Expect ("<a><!-- open</a>", "1:4: the comment is not closed");
      Expect ("<a><![CDATA[x</a>", "1:4: the CDATA section is not closed");
      Expect ("<!DOCTYPE a><a/>", "1:1: a document type declaration");
      Expect ("<a><!ENTITY x></a>", "1:4: <! begins nothing");
      Expect ("<a>< b</a>", "1:4: < begins no tag");
      Expect ("<a/><b/>", "1:5: only comments, processing instructions");
      Expect ("<a/>text", "1:5: only comments");
      Expect (LF & "<?xml version=""1.0""?><a/>",
              "2:1: an XML declaration belongs only");
      Expect ("<?xml encoding=""UTF-8""?><a/>",
              "1:7: the XML declaration names its version first");
      Expect ("<?xml version=""2.0""?><a/>",
              "1:7: the XML declaration's version is 2.0");
      Expect ("<?xml version=""1.0"" encoding=""latin1""?><a/>",
              "1:21: the XML declaration names the encoding latin1");
      Expect ("<a>" & Character'Val (16#C3#) & "</a>",
              "1:4: a UTF-8 character is cut short");
      Expect ("<a>" & Character'Val (16#C0#) & Character'Val (16#80#)
              & "</a>", "1:4: a byte that begins no UTF-8 character");
      Expect ("<a>" & Character'Val (16#E0#) & Character'Val (16#80#)
              & Character'Val (16#80#) & "</a>",
              "1:4: an overlong UTF-8 form");
      Expect ("<a>" & ASCII.NUL & "</a>",
              "1:4: a control character XML does not admit");
      Expect ("<a" & LF & "  b='1'", "1:1: the document ends inside a");
      declare
         Deep : String (1 .. 3 * (Landin.Xml.Maximum_Depth + 1));
      begin
         for Level in 0 .. Landin.Xml.Maximum_Depth loop
            Deep (3 * Level + 1 .. 3 * Level + 3) := "<a>";
         end loop;
         Expect (Deep, "1:193: elements are nested deeper than 64");
      end;
   end Every_Refusal_Is_Placed;

   procedure Hostile_Bytes_Never_Raise
     (Item : in out Landin.Testing.Context);

   procedure Hostile_Bytes_Never_Raise
     (Item : in out Landin.Testing.Context)
   is
      State : Interfaces.Unsigned_64 := 16#5EED_0F_5D#;

      function Next return Interfaces.Unsigned_64;

      function Next return Interfaces.Unsigned_64 is
         use type Interfaces.Unsigned_64;
         Z : Interfaces.Unsigned_64;
      begin
         State := State + 16#9E37_79B9_7F4A_7C15#;
         Z := State;
         Z := (Z xor Interfaces.Shift_Right (Z, 30)) * 16#BF58_476D_1CE4_E5B9#;
         Z := (Z xor Interfaces.Shift_Right (Z, 27)) * 16#94D0_49BB_1331_11EB#;
         return Z xor Interfaces.Shift_Right (Z, 31);
      end Next;

      function Below (Bound : Positive) return Natural
        is (Natural (Interfaces."mod" (Next, Interfaces.Unsigned_64 (Bound))));

      Alphabet : constant String := "<>/?!-[]&#;=""' axCDAT" & LF & CR;
      Survived : Natural := 0;
   begin
      for Round in 1 .. 4_000 loop
         declare
            Length : constant Natural := Below (64);
            Text   : String (1 .. Length);
            Mutant : String := Device;
         begin
            for Index in Text'Range loop
               Text (Index) :=
                 (if Below (4) = 0 then Character'Val (Below (256))
                  else Alphabet (Alphabet'First + Below (Alphabet'Length)));
            end loop;
            for Change in 1 .. 1 + Below (3) loop
               Mutant (Mutant'First + Below (Mutant'Length)) :=
                 (if Below (2) = 0 then Character'Val (Below (256))
                  else Alphabet (Alphabet'First + Below (Alphabet'Length)));
            end loop;
            declare
               Document : X.Document;
            begin
               X.Parse (Document, Text);
               X.Parse (Document, Mutant);
               if not X.Ok (Document) then
                  --  A refusal says where, inside the text.
                  if X.Fault_At (Document) > Mutant'Length
                    or else X.Fault (Document) = ""
                  then
                     Landin.Testing.Fail
                       (Item, "a refusal names no place: " & Mutant);
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
        (Into, "xml", "elements are read", Elements_Are_Read'Access);
      Landin.Testing.Register
        (Into, "xml", "references are decoded",
         References_Are_Decoded'Access);
      Landin.Testing.Register
        (Into, "xml", "every refusal is placed",
         Every_Refusal_Is_Placed'Access);
      Landin.Testing.Register
        (Into, "xml", "hostile bytes never raise",
         Hostile_Bytes_Never_Raise'Access);
   end Register;

end Landin.Tests.Xml_Suite;
