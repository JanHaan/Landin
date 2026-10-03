--  A filesystem with some files' bytes held in memory.
--
--  An editor holds a buffer that differs from the file it will be saved as,
--  or that has never been saved at all, and a server must read it exactly as
--  `refine` would read the saved file: the same loader, the same module
--  discovery, the same bytes.  So the buffer is put where the loader looks,
--  as a file of the host it already reads, rather than handed to it by a
--  second path.  A test that compiles a fixture again after its fixes does
--  the same with the repository underneath.
--
--  A held path is read from here and every other from the host beneath.  A
--  held path the host does not have is listed in its directory, so a new
--  buffer in a module directory is one of the module's files [1410]; its
--  directory is the text before its last '/', compared as bytes, because a
--  held path is a name the holder chose and not one the host resolved.
--  Nothing is written or removed through an overlay: every write and every
--  removal is refused, and the host beneath is never changed by one.

private with Ada.Containers.Indefinite_Ordered_Maps;

package Landin.Platform.Overlays is

   type Overlay (Under : not null access constant Filesystem'Class) is
     limited new Filesystem with private;

   --  Hold Content for Path, replacing what was held there.
   procedure Hold (Host : in out Overlay; Path : String; Content : String);

   --  Stop holding Path, so it is read from the host again.
   procedure Release (Host : in out Overlay; Path : String);

   function Holds (Host : Overlay; Path : String) return Boolean;

   overriding function Exists
     (Host : Overlay; Path : String) return Boolean;

   overriding function Working_Directory (Host : Overlay) return String;

   overriding function Paths_Overlap
     (Host : Overlay; Left, Right : String) return Boolean;

   overriding function Same_File
     (Host : Overlay; Left, Right : String) return Boolean;

   overriding function Is_Directory
     (Host : Overlay; Path : String) return Boolean;

   overriding procedure Read_File
     (Host    : Overlay;
      Path    : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Read_Status);

   overriding procedure Write_File
     (Host    : Overlay;
      Path    : String;
      Content : String;
      Status  : out Write_Status);

   overriding procedure Replace_File
     (Host    : Overlay;
      Path    : String;
      Content : String;
      Status  : out Write_Status);

   overriding procedure Remove_File
     (Host   : Overlay;
      Path   : String;
      Status : out Remove_Status);

   overriding procedure List_Directory
     (Host    : Overlay;
      Path    : String;
      Entries : out Path_List;
      Status  : out List_Status);

private

   --  Ordered, so a directory's held entries are found in the order a
   --  listing returns them.
   package Content_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => String);

   type Overlay (Under : not null access constant Filesystem'Class) is
     limited new Filesystem with record
      Held : Content_Maps.Map;
   end record;

end Landin.Platform.Overlays;
