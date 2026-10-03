--  What the editor holds open, and where each file belongs.
--
--  A document is a URI, a version and its whole text, replaced by every
--  change: the server asks for full synchronisation, so a change is the
--  buffer as it now is and never an edit to apply.  The open documents are
--  held over the host's filesystem by path, so the loader reads a buffer
--  exactly where it would read the saved file.
--
--  A file belongs where `refine` would compile it [1410]-[1420]: a `file:`
--  URI's directory is its entry module, loaded under the server's roots.
--  With no roots, or for a URI that names no file, the buffer is analysed
--  alone, as `refine FILE` would analyse it.

with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Unbounded;

with Landin.Platform;
with Landin.Platform.Overlays;
with Landin.Server.Analysis;

package Landin.Server.Documents is

   --  A `file:` URI's path, percent-decoded, or "" for any other URI.  A
   --  path holding a NUL or a `..` segment is no path.
   function Path_Of (URI : String) return String;

   --  A root URI names a directory.  Accept a final slash and return the
   --  same path as the URI without it (including percent-encoded slashes).
   function Root_Path_Of (URI : String) return String;

   --  The `file:` URI of an absolute path, percent-encoding every byte
   --  that is not unreserved or '/'.
   function URI_Of (Path : String) return String;

   --  Where an untitled buffer is held: under a directory no host has,
   --  named by its URI, so it is always analysed alone.
   function Untitled_Path (URI : String) return String;

   type Document is record
      URI     : Ada.Strings.Unbounded.Unbounded_String;
      Path    : Ada.Strings.Unbounded.Unbounded_String;
      Text    : Ada.Strings.Unbounded.Unbounded_String;
      Version : Long_Long_Integer := 0;
   end record;

   package Document_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Document);

   type Store
     (Under : not null access constant Landin.Platform.Filesystem'Class)
   is limited record
      Open       : Document_Maps.Map;            --  by URI
      Held       : Landin.Platform.Overlays.Overlay (Under);
      Active_URI : Ada.Strings.Unbounded.Unbounded_String;
      Roots      : Landin.Platform.Path_List;    --  in search order
   end record;

   procedure Open
     (Into : in out Store; URI : String; Version : Long_Long_Integer;
      Text : String);

   procedure Change
     (Into : in out Store; URI : String; Version : Long_Long_Integer;
      Text : String);

   procedure Close (Into : in out Store; URI : String);

   --  Project this URI's text over its path before reading or analysing it.
   --  Distinct file URIs may name the same path.
   procedure Activate
     (Into : in out Store; URI : String; Changed : out Boolean);

   function Is_Open (From : Store; URI : String) return Boolean;

   --  The path a URI's buffer is held at.
   function Held_Path (From : Store; URI : String) return String
     with Pre => Is_Open (From, URI);

   --  What analysing the module of URI asks the loader for.
   function Request_For (From : Store; URI : String)
     return Landin.Server.Analysis.Request
     with Pre => Is_Open (From, URI);

   --  A key naming that module: its entry directory, or the held path of a
   --  file analysed alone.  Two open documents with one key are analysed
   --  together.
   function Module_Key (From : Store; URI : String) return String
     with Pre => Is_Open (From, URI);

   --  The URI a report about Path is published under: the preferred or
   --  active document held there, another open document, or Path's URI.
   function URI_For
     (From : Store; Path : String; Preferred : String := "") return String;

end Landin.Server.Documents;
