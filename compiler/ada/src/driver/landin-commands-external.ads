--  The commands `refine` does not hold itself (D1384, D1387).
--
--  A command name that is no built-in one is a split command `refine` was
--  built with, `libexec/landin/refine-NAME` beside the executable's own
--  directory and nowhere else, or a contributed `refine-NAME` on the
--  search path.  Before `refine` runs one, lists it or forwards a code to
--  it, the command describes itself, and `refine` judges from that
--  description whether it is compatible.  What a command is told when it
--  runs is D1486's: the path of the `refine` that dispatched it.
--
--  Every host effect goes through Landin.Platform: the executable's
--  directory and whether a file is there through the filesystem, the
--  search path and the runs through the tool runner.

with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Landin.Platform;

package Landin.Commands.External is

   --  D1387: how long a command may take to describe itself.
   Description_Limit : constant Duration := 10.0;

   --  D1387: the one format of a description this refine reads.
   Description_Format : constant String := "landin-command-1";

   --  D1486: the variable that tells a dispatched command which `refine`
   --  dispatched it.
   Caller_Variable : constant String := "LANDIN_REFINE";

   --  D1484: a word `refine` may dispatch: an ASCII letter, then letters,
   --  digits, `-` and `_`.  A path, a `.ldn` source and an option never are.
   function Is_Command_Name (Word : String) return Boolean;

   --  The names in List, separated by single spaces, as
   --  Landin.Build_Identity.Split_Commands holds them (D1483).
   function Names (List : String) return Landin.Platform.Path_List;

   --  Where NAME's executable is, or would be: the shipped one under the
   --  executable's prefix, `PREFIX/libexec/landin/refine-NAME`, or "" when
   --  the host cannot say where the executable is.
   function Shipped_Path
     (Host : Landin.Platform.Filesystem'Class; Name : String) return String;

   type Kind is (Absent, Shipped, Shipped_Missing, Contributed);

   type Location is record
      Of_Kind : Kind := Absent;
      --  Where it is; for Shipped_Missing, where it was looked for, or ""
      --  when the host could not say where refine is.
      Path : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  D1384: a split command `refine` was built with is looked for beside
   --  it alone; any other name on the search path.
   function Locate
     (Name    : String;
      Host    : Landin.Platform.Filesystem'Class;
      Tools   : Landin.Platform.Tool_Runner'Class;
      Shipped : Landin.Platform.Path_List) return Location;

   type Description is record
      Compatible : Boolean := False;
      --  Why it is not compatible: what was asked and what came back.
      Reason  : Ada.Strings.Unbounded.Unbounded_String;
      Summary : Ada.Strings.Unbounded.Unbounded_String;
      --  The prefixes a contributed command claims.
      Codes   : Landin.Platform.Path_List;
   end record;

   --  D1387: ask the command at Path to describe itself and judge the
   --  answer.  A shipped command must name the source digest Digest.
   function Describe
     (Name, Path : String;
      Is_Shipped : Boolean;
      Tools      : Landin.Platform.Tool_Runner'Class;
      Digest     : String) return Description;

   type Found_Command (Name_Length, Path_Length : Natural) is record
      Name       : String (1 .. Name_Length);
      Path       : String (1 .. Path_Length);
      Is_Shipped : Boolean;
      Missing    : Boolean;
      About      : Description;
   end record;

   package Found_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Found_Command);

   --  D1384: every external command, described: each shipped one, there
   --  or missing, then each contributed one on the search path whose name
   --  no built-in or shipped command has, sorted by name.  Contributed
   --  only leaves the shipped ones out.
   function Scan
     (Host        : Landin.Platform.Filesystem'Class;
      Tools       : Landin.Platform.Tool_Runner'Class;
      Shipped     : Landin.Platform.Path_List;
      Digest      : String;
      Contributed : Boolean := False) return Found_Vectors.Vector;

   --  The lines `refine help` adds under its own heading, or "" when the
   --  scan found nothing.
   function Help_Lines (Found : Found_Vectors.Vector) return String;

   --  D1385: the prefix of a code `refine explain` forwards: two to eight
   --  capital ASCII letters followed by at least one digit and nothing
   --  else, or "" for any other word.
   function Forwarded_Prefix (Code : String) return String;

   --  The refusal of a shipped command that is missing.
   function Missing_Message (Name : String; Where : Location) return String;

   --  The refusal of an incompatible command: its path, what refine asked,
   --  what came back and what to do.
   function Incompatible_Message
     (Name : String; Where : Location; About : Description) return String;

end Landin.Commands.External;
