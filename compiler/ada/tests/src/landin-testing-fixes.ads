--  Applying a report's fixes, which only a test does.
--
--  The compiler builds fixes and never applies one: an editor or a person
--  does that.  The harness applies them to prove that each is what it
--  claims, so the one routine that does it lives on the test side, where no
--  stage can come to depend on it.

with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Landin.Diagnostics;
with Landin.Platform;
with Landin.Platform.Native;
with Landin.Source;

package Landin.Testing.Fixes is

   --  Text with every edit that names Source applied, taken from the first
   --  fix of each diagnostic in Found that has one.  Edits are applied from
   --  the end of the text towards its start, so each one's offsets are the
   --  offsets of the text the compilation read.  Two edits from different
   --  diagnostics that overlap cannot both be applied, and Clashed says so.
   function Applied
     (Found   : Landin.Diagnostics.Diagnostic_List;
      Source  : Landin.Source.Source_Id;
      Text    : String;
      Clashed : out Boolean) return String;

   --  Whether some diagnostic's first fix edits Source.
   function Edits
     (Found  : Landin.Diagnostics.Diagnostic_List;
      Source : Landin.Source.Source_Id) return Boolean;

   --  The real host with some files' bytes replaced, which is how a rooted
   --  fixture is compiled again after its fixes: its module closure is the
   --  repository's, so it is read from the real tree, which is the
   --  deliberate exception every rooted fixture case makes.  Only reads are
   --  replaced; nothing here writes.
   type Overlay_Filesystem is limited new Landin.Platform.Filesystem
     with private;

   procedure Replace
     (Host : in out Overlay_Filesystem; Path : String; Content : String);

   overriding function Exists
     (Host : Overlay_Filesystem; Path : String) return Boolean;

   overriding function Working_Directory
     (Host : Overlay_Filesystem) return String;

   overriding function Paths_Overlap
     (Host : Overlay_Filesystem; Left, Right : String) return Boolean;

   overriding function Same_File
     (Host : Overlay_Filesystem; Left, Right : String) return Boolean;

   overriding function Is_Directory
     (Host : Overlay_Filesystem; Path : String) return Boolean;

   overriding procedure Read_File
     (Host    : Overlay_Filesystem;
      Path    : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Landin.Platform.Read_Status);

   overriding procedure Write_File
     (Host    : Overlay_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Landin.Platform.Write_Status);

   overriding procedure Remove_File
     (Host   : Overlay_Filesystem;
      Path   : String;
      Status : out Landin.Platform.Remove_Status);

   overriding procedure List_Directory
     (Host    : Overlay_Filesystem;
      Path    : String;
      Entries : out Landin.Platform.Path_List;
      Status  : out Landin.Platform.List_Status);

private

   package Content_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => String,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   type Overlay_Filesystem is limited new Landin.Platform.Filesystem
   with record
      Real     : Landin.Platform.Native.Native_Filesystem;
      Replaced : Content_Maps.Map;
   end record;

end Landin.Testing.Fixes;
