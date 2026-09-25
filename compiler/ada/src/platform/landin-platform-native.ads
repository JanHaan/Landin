--  The real host.
--
--  This is the only place in the compiler that touches a filesystem or
--  starts a process.  Everything above it sees Landin.Platform's interfaces,
--  which is what lets the whole test suite run without a temporary
--  directory.

with Ada.Strings.Unbounded;

package Landin.Platform.Native is

   type Native_Filesystem is limited new Filesystem with null record;

   overriding function Exists
     (Host : Native_Filesystem; Path : String) return Boolean;

   overriding function Same_File
     (Host : Native_Filesystem; Left, Right : String) return Boolean;

   overriding function Paths_Overlap
     (Host : Native_Filesystem; Left, Right : String) return Boolean;

   overriding function Working_Directory
     (Host : Native_Filesystem) return String;

   overriding function Is_Directory
     (Host : Native_Filesystem; Path : String) return Boolean;

   overriding procedure Read_File
     (Host    : Native_Filesystem;
      Path    : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Read_Status);

   overriding procedure Write_File
     (Host    : Native_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Write_Status);

   overriding procedure Remove_File
     (Host   : Native_Filesystem;
      Path   : String;
      Status : out Remove_Status);

   overriding procedure List_Directory
     (Host    : Native_Filesystem;
      Path    : String;
      Entries : out Path_List;
      Status  : out List_Status);

   --  The process's own counters, read through the host C adapter
   --  `landin_resource_usage.c`.  A host that refuses the query raises
   --  Host_Exhausted, the same outcome as any other lost host resource.
   type Native_Meter is limited new Resource_Meter with null record;

   overriding function Sample (Host : Native_Meter) return Resource_Sample;

end Landin.Platform.Native;
