--  The syntax stage.
--
--  The first stage that reads Landin rather than describing the chassis: it
--  scans every source in the compilation, reports what the scan could not
--  read, parses what it produced, and reports what the parse could not
--  read.  Both halves report, and in that order, so a file with an
--  unreadable byte and a missing `then` says both things rather than
--  stopping at the first.
--
--  It keeps nothing of its own.  The tree of each source goes into the
--  compilation's forest, its space and comments beside it, and the
--  identities it interned are the compilation's too, because all three
--  outlive this Run: the stage that resolves names runs after it returns,
--  a Name_Id in a tree names a spelling in one table, and a formatter reads
--  the space after every stage has finished.  The stage object holds
--  nothing at all, which is what lets one library-level instance serve
--  every compilation.

private with Ada.Containers.Indefinite_Ordered_Maps;
private with Ada.Containers.Indefinite_Ordered_Sets;
private with Ada.Finalization;
private with Ada.Strings.Unbounded;

with Landin.Diagnostics;
with Landin.Source.Names;
with Landin.Syntax.Forest;
with Landin.Tokens.Spacing;

package Landin.Stages.Syntax is

   type Instance is limited new Landin.Stages.Stage with null record;

   overriding function Name (Item : Instance) return String;

   overriding procedure Run
     (Item    : Instance;
      Whole   : in out Compilation'Class;
      Outcome : out Stage_Outcome);

   --  One publication round may reuse exact source parses across its
   --  separate compilations.  The cache ends before the next editor event.
   type Parse_Cache is tagged limited private;

   function Reuse_Count (Cache : Parse_Cache) return Natural;
   function Stored_Count (Cache : Parse_Cache) return Natural;

   --  Limit stored parses to paths shared by the pending publications.
   --  With no limit, callers may cache any source.
   procedure Limit_To (Cache : in out Parse_Cache; Path : String);

   --  Snapshot held editor bytes once for this publication round.  The
   --  loader uses these only for imported modules, never an entry stand-in.
   procedure Hold (Cache : in out Parse_Cache; Path, Text : String);
   function Holds (Cache : Parse_Cache; Path : String) return Boolean;
   function Held_Text (Cache : Parse_Cache; Path : String) return String
     with Pre => Holds (Cache, Path);

   procedure Run_With_Cache
     (Whole   : in out Compilation'Class;
      Cache   : in out Parse_Cache;
      Outcome : out Stage_Outcome);


   --  Reuse unchanged parsed sources from Previous when source identities
   --  and text agree. The caller first copies Previous's interned names in
   --  their original order into Whole. Watch marks each actual lex/parse.
   procedure Run_Using
     (Whole    : in out Compilation'Class;
      Outcome  : out Stage_Outcome;
      Previous : access Compilation := null;
      Watch    : access procedure (Name : String) := null;
      Cache    : access Parse_Cache'Class := null);

private

   type Cache_Entry;
   type Entry_Access is access Cache_Entry;
   type Cache_Entry is limited record
      Text   : Ada.Strings.Unbounded.Unbounded_String;
      Names  : Landin.Source.Names.Table;
      Trees  : Landin.Syntax.Forest.Table;
      Spaces : Landin.Tokens.Spacing.Table;
      Found  : Landin.Diagnostics.Diagnostic_List;
      Next   : Entry_Access := null;
   end record;
   package Entry_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Entry_Access);
   package Text_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => String);
   package Path_Sets is new Ada.Containers.Indefinite_Ordered_Sets
     (Element_Type => String);

   type Parse_Cache is new Ada.Finalization.Limited_Controlled with record
      Entries : Entry_Maps.Map;
      Held    : Text_Maps.Map;
      Allowed : Path_Sets.Set;
      Reused  : Natural := 0;
      Stored  : Natural := 0;
   end record;

   overriding procedure Finalize (Cache : in out Parse_Cache);

end Landin.Stages.Syntax;
