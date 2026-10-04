--  Editable source held as slices of immutable byte strings.
--
--  A ranged edit splits and relinks slices; it never copies the unchanged
--  suffix.  Each string counts the slices that name it and is freed with
--  the last of them.  A string a slice still names keeps its deleted bytes
--  too, so once those outweigh the text the text is copied into one
--  string: retained string payload bytes stay within twice the visible
--  bytes. Slice metadata, allocator overhead and transient copies are extra.
--  Materialize only when the compiler needs a contiguous source.

with Ada.Containers.Doubly_Linked_Lists;
with Ada.Finalization;

with Landin.Server.Positions;

package Landin.Server.Texts is

   type Buffer is new Ada.Finalization.Limited_Controlled with private;

   procedure Open (Into : in out Buffer; Text : String);

   --  Whether First is not after Last.  A position is read as Positions
   --  reads one, so the bytes such a range names never end before they
   --  begin, and an edit with it cannot fail.
   function In_Order (First, Last : Positions.Position) return Boolean
     is (First.Line < Last.Line
         or else (First.Line = Last.Line
                  and then First.Character <= Last.Character));

   --  Replace one range, in the negotiated units, with Text.
   procedure Edit
     (Into : in out Buffer;
      First, Last : Positions.Position;
      Unit : Positions.Encoding; Text : String)
     with Pre => In_Order (First, Last);

   --  Replace the entire text.
   procedure Replace (Into : in out Buffer; Text : String);

   function Content (From : Buffer) return String;
   function Length (From : Buffer) return Natural;
   function Is_Dirty (From : Buffer) return Boolean;

   --  The byte strings still owned and their bytes, to check that edits
   --  retain only text that is still shown.
   function Stored_Strings (From : Buffer) return Natural;
   function Stored_Bytes (From : Buffer) return Natural;

private

   type String_Access is access String;

   type Block is record
      Data  : String_Access;
      Users : Natural := 0;     --  the slices naming Data
   end record;

   type Block_Access is access Block;

   type Piece is record
      Data   : Block_Access;
      First  : Positive;
      Length : Positive;
   end record;

   package Piece_Lists is new Ada.Containers.Doubly_Linked_Lists (Piece);

   type Buffer is new Ada.Finalization.Limited_Controlled with record
      Pieces  : Piece_Lists.List;
      Length  : Natural := 0;
      Strings : Natural := 0;
      Bytes   : Natural := 0;
      Dirty   : Boolean := False;
   end record;

   overriding procedure Finalize (Into : in out Buffer);

end Landin.Server.Texts;
