--  Where a byte is, as an editor counts.
--
--  The compiler counts a byte offset into a source; an editor counts a
--  zero-based line and a character within it, and what a character is was
--  negotiated: UTF-16 code units unless both sides said UTF-8.  This is the
--  only place either is turned into the other, so a column is never counted
--  twice in two ways.
--
--  Lines end at LF, CR LF or a lone CR [1750], as the protocol's own
--  definition has them.  In UTF-16 a character above U+FFFF is two units,
--  and a byte that is not part of well-formed UTF-8 is one unit, as an
--  editor that decoded the file with replacement characters counts it.  A
--  position past the end of its line is the line's end, and one that falls
--  inside a character is that character's first byte, so any position an
--  editor sends names a byte boundary of the source.

private with Ada.Containers.Vectors;

with Landin.Source;

package Landin.Server.Positions is

   type Encoding is (UTF_8, UTF_16);

   type Position is record
      Line      : Natural := 0;
      Character : Natural := 0;
   end record;

   --  A batch holds only its requested endpoints.  Register them before
   --  Prepare, which sorts them and scans Text once in offset order.
   type Position_Map is tagged private;

   procedure Register
     (Map : in out Position_Map; Offset : Landin.Source.Byte_Offset);
   procedure Prepare
     (Map : in out Position_Map; Text : String; Unit : Encoding);
   function Endpoint_Count (Map : Position_Map) return Natural;
   function Ready (Map : Position_Map) return Boolean;
   function Position_Of
     (Map : Position_Map; Offset : Landin.Source.Byte_Offset)
      return Position;

   --  Text is the whole source.  Offset is at most its length.
   function Position_Of
     (Text   : String;
      Offset : Landin.Source.Byte_Offset;
      Unit   : Encoding) return Position;

   --  The byte a position names, clamped to its line and to the text.
   function Offset_Of
     (Text  : String;
      Where : Position;
      Unit  : Encoding) return Landin.Source.Byte_Offset;

   --  For text that is not one string, the pieces Offset_Of counts with.
   --  Width is the byte length of the character that begins with Lead,
   --  given the bytes after it (-1 past the end), by Unicode's well-formed
   --  table: 1 for a byte that begins nothing well formed.
   function Width
     (Lead, Second, Third, Fourth : Integer) return Positive;

   --  How many units a character of Bytes bytes is.
   function Units (Bytes : Positive; Unit : Encoding) return Positive
     is (case Unit is
           when UTF_8  => Bytes,
           when UTF_16 => (if Bytes = 4 then 2 else 1));

private

   type Endpoint is record
      Offset : Landin.Source.Byte_Offset;
      At_Pos : Position;
   end record;

   package Endpoint_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Endpoint);

   type Position_Map is tagged record
      Points : Endpoint_Vectors.Vector;
      Built  : Boolean := False;
   end record;

end Landin.Server.Positions;
