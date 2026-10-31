--  XML, read, in the subset a CMSIS-SVD file is written in (D555).
--
--  A device's SVD is a vendor's file, fetched by its hash and never edited,
--  so the reader is strict rather than forgiving: what it reads it reads
--  exactly, and anything else is refused with the line and column it was
--  met at, never raised.  It reads XML 1.0's well-formed documents without
--  a document type declaration:
--
--  * an optional byte order mark and XML declaration, whose encoding, when
--    it names one, is UTF-8;
--  * elements, their attributes, and character data, in which the five
--    predefined entities and decimal and hexadecimal character references
--    are decoded and line ends are read as XML says, CR LF and CR as LF;
--  * CDATA sections, copied as written;
--  * comments and processing instructions, which are skipped.
--
--  What it refuses, and why:
--
--  * a document type declaration, and with it every entity but the five
--    predefined ones: an SVD needs none, and an entity a file declares is
--    the one way XML has of making a small file large;
--  * bytes that are not UTF-8, and characters XML does not admit;
--  * an end tag that does not close the element open, an attribute given
--    twice, a `<` in an attribute value, `]]>` in character data, `--`
--    inside a comment, and text outside the root element;
--  * nesting deeper than Maximum_Depth, which no SVD approaches and which
--    bounds what a hostile file can make the reader hold open.
--
--  A document is a flat table of elements, freed with the document; an
--  element is found by index, its attributes by position or name and its
--  children by walking them, so nothing a reader holds outlives the
--  document.  Lines count from one at each LF; columns count bytes from one,
--  as refine's diagnostics do.

private with Ada.Containers.Vectors;
private with Ada.Strings.Unbounded;

package Landin.Xml is

   Maximum_Depth : constant := 64;

   type Document is limited private;

   type Element is private;

   No_Element : constant Element;

   --  Parse Text.  Ok says whether it was one well-formed document; when
   --  it was not, Fault says why and Fault_At, Fault_Line and
   --  Fault_Column where, and the document holds nothing.
   procedure Parse (Into : in out Document; Text : String);

   function Ok (Of_Document : Document) return Boolean;

   function Fault (Of_Document : Document) return String;

   --  A zero-based byte offset into the text parsed.
   function Fault_At (Of_Document : Document) return Natural;

   function Fault_Line (Of_Document : Document) return Positive;

   function Fault_Column (Of_Document : Document) return Positive;

   --  The line and column of a zero-based byte offset into the text the
   --  document was parsed from, for a reader that refuses what an element
   --  says rather than how it is written.
   function Line_Of (Of_Document : Document; Offset : Natural)
     return Positive;

   function Column_Of (Of_Document : Document; Offset : Natural)
     return Positive;

   function Root (Of_Document : Document) return Element
     with Pre => Ok (Of_Document);

   function Is_Present (Item : Element) return Boolean;

   function Name (Of_Document : Document; Item : Element) return String
     with Pre => Is_Present (Item);

   --  Where the element's start tag begins: the zero-based offset of its
   --  `<`, and that offset's line and column.
   function Offset (Of_Document : Document; Item : Element) return Natural
     with Pre => Is_Present (Item);

   function Line (Of_Document : Document; Item : Element) return Positive
     with Pre => Is_Present (Item);

   function Column (Of_Document : Document; Item : Element) return Positive
     with Pre => Is_Present (Item);

   --  The element's own character data, its references decoded and its
   --  CDATA copied, in document order and without its children's.
   function Text (Of_Document : Document; Item : Element) return String
     with Pre => Is_Present (Item);

   --  Where the element's own character data begins, or its start tag's
   --  offset when it has none; for a refusal of a value to point at.
   function Text_Offset (Of_Document : Document; Item : Element)
     return Natural
     with Pre => Is_Present (Item);

   function Attribute_Count (Of_Document : Document; Item : Element)
     return Natural
     with Pre => Is_Present (Item);

   function Attribute_Name
     (Of_Document : Document; Item : Element; Position : Positive)
      return String
     with Pre => Is_Present (Item)
                 and then Position <= Attribute_Count (Of_Document, Item);

   function Attribute_Value
     (Of_Document : Document; Item : Element; Position : Positive)
      return String
     with Pre => Is_Present (Item)
                 and then Position <= Attribute_Count (Of_Document, Item);

   function Has_Attribute
     (Of_Document : Document; Item : Element; Name : String) return Boolean
     with Pre => Is_Present (Item);

   --  The attribute's decoded value, or "" when the element has none of
   --  that name.
   function Attribute
     (Of_Document : Document; Item : Element; Name : String) return String
     with Pre => Is_Present (Item);

   --  The element's first child element, and the element after one among
   --  its parent's children; No_Element when there is none.
   function First_Child (Of_Document : Document; Item : Element)
     return Element
     with Pre => Is_Present (Item);

   function Next_Sibling (Of_Document : Document; Item : Element)
     return Element
     with Pre => Is_Present (Item);

   --  The first child element named Name, or No_Element.
   function Child
     (Of_Document : Document; Item : Element; Name : String) return Element
     with Pre => Is_Present (Item);

   --  How many child elements are named Name.
   function Child_Count
     (Of_Document : Document; Item : Element; Name : String) return Natural
     with Pre => Is_Present (Item);

private

   type Element is new Natural;

   No_Element : constant Element := 0;

   type Node is record
      Name_First, Name_Last : Natural := 0;
      Text_First, Text_Last : Natural := 0;
      Text_Offset : Natural := 0;
      Has_Text : Boolean := False;
      First_Attribute : Natural := 0;
      Attributes : Natural := 0;
      First_Child, Last_Child, Next_Sibling : Element := No_Element;
      Offset : Natural := 0;
   end record;

   package Node_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Node);

   type Attribute_Entry is record
      Name_First, Name_Last : Natural := 0;
      Value_First, Value_Last : Natural := 0;
   end record;

   package Attribute_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Attribute_Entry);

   package Offset_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Natural);

   type Document is limited record
      Nodes : Node_Vectors.Vector;
      Attributes : Attribute_Vectors.Vector;
      --  Every name, attribute value and text, one after another; a node
      --  holds the bounds of its own.
      Pool : Ada.Strings.Unbounded.Unbounded_String;
      --  The offset each line begins at, the first line's being zero.
      Line_Starts : Offset_Vectors.Vector;
      Parsed : Boolean := False;
      Failure : Ada.Strings.Unbounded.Unbounded_String;
      Failure_At : Natural := 0;
   end record;

end Landin.Xml;
