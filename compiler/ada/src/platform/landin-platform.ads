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
   type Remove_Status is (Removed, Already_Absent, Not_Removable);
   type Move_Status is (Moved, Move_Source_Absent, Not_Movable);
   type List_Status is
     (List_Ok, Directory_Not_Found, Not_A_Directory,
      Directory_Not_Readable);

   ---------------------------------------------------------------------
   --  Filesystem
   ---------------------------------------------------------------------

   type Filesystem is limited interface;

   function Exists (Host : Filesystem; Path : String) return Boolean
     is abstract;

   --  Debug-only path context.  Virtual filesystems may leave it empty;
   --  native adapters supply the absolute directory without rewriting inputs.
   function Working_Directory (Host : Filesystem) return String is abstract;

   --  True for names of the same object, including links and relative paths,
   --  or when identity cannot safely be distinguished. Missing output leaves
   --  use actual parent identity and destination-filesystem name equivalence,
   --  not lexical dot collapse or host-wide case folding. This is a preflight
   --  guard, not protection against concurrent filesystem replacement.
   function Paths_Overlap
     (Host : Filesystem; Left, Right : String) return Boolean is abstract;

   --  True only for proven identity of existing objects. Unknown identity
   --  is False: source deduplication must never discard an uncertain input.
   --  Like Paths_Overlap, this assumes no concurrent namespace replacement.
   function Same_File
     (Host : Filesystem; Left, Right : String) return Boolean is abstract;

   --  A stable key for a proven existing object, equal for every spelling
   --  of that object and different for distinct objects. Empty means the
   --  host cannot establish a key; callers then use Same_File. The key is
   --  only meaningful within one host and one stable namespace.
   function Existing_File_Key (Host : Filesystem; Path : String)
     return String is abstract;

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

   --  Replace an existing ordinary file only after all new bytes have been
   --  written.  On failure its original bytes remain.  The native adapter
   --  follows a symlink to its target and refuses hard-linked targets. It
   --  needs write permission in the target's directory to create and rename
   --  the sibling file. On success it copies owner, group, and mode bits
   --  (including special bits). ACLs and xattrs cause safe refusal, as does
   --  failure to establish their absence. Linux may refuse ordinary users
   --  who cannot inspect privileged attributes. Timestamps may change.
   --  It syncs the file, not the parent directory, so crash durability of
   --  the renamed directory entry is not guaranteed.
   procedure Replace_File
     (Host    : Filesystem;
      Path    : String;
      Content : String;
      Status  : out Write_Status) is abstract;

   --  Remove one file, never a directory. Missing files already meet the
   --  absence requirement. Establish fresh output without reading old bytes.
   procedure Remove_File
     (Host   : Filesystem;
      Path   : String;
      Status : out Remove_Status) is abstract;

   --  Move one file without replacing an existing destination. Used to keep
   --  an earlier executable while a tool produces a fresh one.
   procedure Move_File
     (Host   : Filesystem;
      From, To : String;
      Status : out Move_Status) is abstract;

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
   --  description carries them: `Landin.Backend.Toolchain` names them from
   --  the target's triplet.
   ---------------------------------------------------------------------

   --  How a run ended, which is not the same question as what it returned.
   --  A program that a signal killed has no exit status at all, and on a
   --  POSIX host the two are separate fields of one wait result; folding
   --  them into an integer is what makes a killed program indistinguishable
   --  from one that exited with some number.  A watchdog expiration is also
   --  separate: the adapter sends a signal to stop the child, but that does
   --  not make an overlong run a program-generated trap.
   --
   --  The native path needs the distinction and not the encoding: `spec.md`
   --  [1960] says a trap's operating-system signal or status is not stable
   --  program behaviour, so a caller may ask whether a program ended normally
   --  and may not ask which signal ended it.  Nothing here carries a signal
   --  number, deliberately.
   type Termination is (Exited, Signaled, Timed_Out);

   type Tool_Result is record
      Ended     : Termination := Exited;
      --  Meaningful when Ended is Exited, and zero otherwise.
      Exit_Code : Integer := 0;
      Output    : Ada.Strings.Unbounded.Unbounded_String;
      --  Separate stderr for Output_Only; empty when streams are merged.
      Error_Output : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Whether the tool's error output is folded into its captured output.
   --  A caller that wants to know which stream a message arrived on has to
   --  be able to ask for them apart. Output_Only captures stderr separately
   --  in Error_Output, so callers can also require that it is empty.
   type Capture_Mode is (Output_Only, Merged);

   type Tool_Runner is limited interface;

   procedure Run
     (Host      : Tool_Runner;
      Program   : String;
      Arguments : Path_List;
      Result    : out Tool_Result;
      Capture   : Capture_Mode := Merged) is abstract;

   --  Answer whether a successful run left the named output as a file.
   --  The caller clears that path before Run, so this is evidence from this
   --  invocation rather than mere evidence of an earlier file.
   function Output_Produced
     (Host : Tool_Runner; Files : Filesystem'Class; Path : String)
      return Boolean is abstract;

   ---------------------------------------------------------------------
   --  Resource measurement
   --
   --  What the host has counted for this process so far: processor time,
   --  user and system together, and the peak resident set.  A measurement
   --  and never an input: nothing a compilation decides may depend on one,
   --  because two runs of the same request differ in both.  Tools the
   --  driver starts are not charged to the compiler.
   --
   --  Allocated_Bytes is what the allocator holds for the process right
   --  now.  The peak only rises, so it cannot say whether a finished
   --  compilation gave its storage back; this falls when storage is freed,
   --  which is the question a process that checks one program after
   --  another has to be able to ask.
   ---------------------------------------------------------------------

   type Resource_Sample is record
      Processor_Microseconds : Long_Long_Integer := 0;
      Peak_Resident_KiB      : Long_Long_Integer := 0;
      Allocated_Bytes        : Long_Long_Integer := 0;
   end record;

   type Resource_Meter is limited interface;

   function Sample (Host : Resource_Meter) return Resource_Sample
     is abstract;

   --  A meter that measures nothing, for a host that offers no counters:
   --  every sample is zero.
   type Unmetered is limited new Resource_Meter with null record;

   overriding function Sample (Host : Unmetered) return Resource_Sample;

   ---------------------------------------------------------------------
   --  A byte channel
   --
   --  What a server talks to its editor through: standard input, output
   --  and error for a real one, scripted bytes for a test.  Bytes and not
   --  lines, because a protocol message carries its own length and a
   --  text-mode read would rewrite line ends out from under it.  Reading
   --  says how many bytes arrived and whether the input has ended; Pending
   --  says whether bytes are waiting now, without waiting for any, which is
   --  how a server with one thread tells a burst of edits from a pause.
   ---------------------------------------------------------------------

   type Channel is limited interface;

   --  Up to Into'Length bytes, waiting for at least one unless the input
   --  has ended.  Last is Into'First - 1 exactly when it has.
   procedure Read
     (Host : in out Channel;
      Into : out String;
      Last : out Natural) is abstract;

   --  Whether a Read would return at least one byte without waiting.
   function Pending (Host : in out Channel) return Boolean is abstract;

   --  Every byte of Item, in order.
   procedure Write (Host : in out Channel; Item : String) is abstract;

   --  A line for a person reading the server's log, never the protocol.
   procedure Log (Host : in out Channel; Line : String) is abstract;

   --  Helpers for building an argument list without exposing the container.
   function No_Arguments return Path_List;
   function Arguments (First : String) return Path_List;
   procedure Add (Into : in out Path_List; Argument : String);

   --  One element per line, joined for a report.
   function Joined (Lines : Path_List) return String;

end Landin.Platform;
