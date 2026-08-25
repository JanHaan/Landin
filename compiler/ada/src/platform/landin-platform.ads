--  Host adapters.
--
--  Every host effect the compiler needs reaches it through one of these
--  interfaces, so a test can build a whole compilation without touching a
--  disk or spawning a process, and so the eventual self-hosting roadmap has
--  exactly one list of things a host must provide.
--
--  Expected failures are results.  A missing file, an unreadable directory
--  or a tool that reported errors are all data the driver can turn into a
--  diagnostic.  The exceptions in Landin are reserved for a compiler defect,
--  an exhausted host, or a tool that could not be run at all.

with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

package Landin.Platform is

   package Path_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   subtype Path_List is Path_Vectors.Vector;

   type Read_Status is (Read_Ok, Not_Found, Not_Readable);
   type Write_Status is (Write_Ok, Not_Writable);
   type List_Status is (List_Ok, Directory_Not_Found, Not_A_Directory);

   ---------------------------------------------------------------------
   --  Filesystem
   ---------------------------------------------------------------------

   type Filesystem is limited interface;

   function Exists (Host : Filesystem; Path : String) return Boolean
     is abstract;

   function Is_Directory (Host : Filesystem; Path : String) return Boolean
     is abstract;

   --  Bytes, not lines: the lexer is byte-oriented and a text-mode read
   --  would quietly rewrite line endings out from under a span.
   procedure Read_File
     (Host    : Filesystem;
      Path    : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Read_Status) is abstract;

   procedure Write_File
     (Host    : Filesystem;
      Path    : String;
      Content : String;
      Status  : out Write_Status) is abstract;

   --  Entry names only, without the directory prefix, sorted so that two
   --  runs discover fixtures in the same order on any host.
   procedure List_Directory
     (Host    : Filesystem;
      Path    : String;
      Entries : out Path_List;
      Status  : out List_Status) is abstract;

   ---------------------------------------------------------------------
   --  External tools
   --
   --  A tool run is described, not spelled: a program name and a list of
   --  arguments, never a shell command line to be re-parsed.  Which
   --  assembler and linker a target uses is not settled here and no target
   --  description carries them yet; that arrives with R1.80, the first
   --  work that has something to assemble.
   ---------------------------------------------------------------------

   --  How a run ended, which is not the same question as what it returned.
   --  A program that a signal killed has no exit status at all, and on a
   --  POSIX host the two are separate fields of one wait result; folding
   --  them into an integer is what makes a killed program indistinguishable
   --  from one that exited with some number.
   --
   --  R1.80 needs the distinction and not the encoding: `spec.md` [1960]
   --  says a trap's operating-system signal or status is not stable program
   --  behaviour, so a caller may ask whether a program ended normally and
   --  may not ask which signal ended it.  Nothing here carries a signal
   --  number, deliberately.
   type Termination is (Exited, Signaled);

   type Tool_Result is record
      Ended     : Termination := Exited;
      --  Meaningful when Ended is Exited, and zero otherwise.
      Exit_Code : Integer := 0;
      Output    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Whether the tool's error output is folded into its captured output.
   --  A caller that wants to know which stream a message arrived on has to
   --  be able to ask for them apart.
   type Capture_Mode is (Output_Only, Merged);

   type Tool_Runner is limited interface;

   procedure Run
     (Host      : Tool_Runner;
      Program   : String;
      Arguments : Path_List;
      Result    : out Tool_Result;
      Capture   : Capture_Mode := Merged) is abstract;

   --  Helpers for building an argument list without exposing the container.
   function No_Arguments return Path_List;
   function Arguments (First : String) return Path_List;
   procedure Add (Into : in out Path_List; Argument : String);

   --  One element per line, joined for a report.
   function Joined (Lines : Path_List) return String;

end Landin.Platform;
