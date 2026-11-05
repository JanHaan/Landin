--  Test doubles for the host.
--
--  An in-memory filesystem and a scripted tool runner.  The suite must be
--  able to prove what the compiler does with an unreadable file or a failing
--  linker without arranging one on the machine running the tests.

with Ada.Containers.Vectors;
with Ada.Exceptions;
with Ada.Finalization;
with Ada.Strings.Unbounded;
with Interfaces;

with Landin.Platform;

package Landin.Testing.Fakes is

   type Fake_Filesystem is limited new Landin.Platform.Filesystem with private;
   type Fake_Filesystem_Access is access all Fake_Filesystem;

   procedure Add_File
     (Host : in out Fake_Filesystem; Path : String; Content : String);

   --  Deterministic metadata race: create a hard link on the second probe.
   procedure Appear_On_Identity_Observation
     (Host : in out Fake_Filesystem; Path, Target : String);
   procedure Set_Identity_Uncertain
     (Host : in out Fake_Filesystem; Path : String);
   overriding function Observe_Identity
     (Host : Fake_Filesystem; Path : String)
      return Landin.Platform.Identity_Observation;

   --  Real direntries sharing an object, and links whose target can dangle.
   procedure Add_Hard_Link
     (Host : in out Fake_Filesystem; Path, Target : String);
   procedure Add_Symbolic_Link
     (Host : in out Fake_Filesystem; Path, Target : String);
   procedure Replace_On_Publication
     (Host : in out Fake_Filesystem;
      Action : Landin.Platform.Publication_Action;
      Path, Content : String; As_Link : Boolean := False);

   --  A path that exists, can be listed, and cannot be read as a file.
   --  Trailing directory separators do not create a different entry.
   procedure Add_Directory (Host : in out Fake_Filesystem; Path : String);

   --  A directory whose entry is visible but whose contents cannot be listed.
   procedure Add_Unlistable_Directory
     (Host : in out Fake_Filesystem; Path : String);

   --  A path that exists and refuses to be read, which is how the driver's
   --  unreadable-source diagnostic gets tested.
   procedure Add_Unreadable (Host : in out Fake_Filesystem; Path : String);

   --  The last bytes written directly to Path, not its current contents:
   --  moving a file onto Path does not update this write record.
   function Written (Host : Fake_Filesystem; Path : String) return String;
   --  Counts attempts, including refused and empty writes.
   function Write_Count (Host : Fake_Filesystem) return Natural;
   function List_Count
     (Host : Fake_Filesystem; Path : String) return Natural;

   overriding function Exists
     (Host : Fake_Filesystem; Path : String) return Boolean;

   --  Existing directories share identity across trailing separators.
   --  Other namespace equivalence, including dot spellings, is explicit.
   --  The fake does not guess native symlink or volume case semantics.
   procedure Add_Alias
     (Host : in out Fake_Filesystem; Left, Right : String);
   overriding function Same_File
     (Host : Fake_Filesystem; Left, Right : String) return Boolean;

   overriding function Existing_File_Key
     (Host : Fake_Filesystem; Path : String) return String;

   overriding function Identity_Of
     (Host : Fake_Filesystem; Path : String)
      return Landin.Platform.File_Identity;

   function Output_Locked (Host : Fake_Filesystem) return Boolean;
   overriding function Existing_Identity
     (Host : Fake_Filesystem; Path : String)
      return Landin.Platform.File_Identity;

   function Same_File_Count (Host : Fake_Filesystem) return Natural;

   overriding function Paths_Overlap
     (Host : Fake_Filesystem; Left, Right : String) return Boolean;

   overriding function Paths_Overlap_Any
     (Host : Fake_Filesystem; Left : String;
      Rights : Landin.Platform.Path_List) return Boolean;

   overriding function Working_Directory
     (Host : Fake_Filesystem) return String is ("/virtual/compile");

   --  Nowhere until a case says where: every case that does not ask about
   --  the library is compiled with none, as before there was one.
   procedure Set_Executable_Directory
     (Host : in out Fake_Filesystem; Directory : String);

   --  D543: a firmware request on a fake host needs the library's
   --  constrained reference description, which a Cortex-M program that
   --  imports no other is given.  This puts the checkout's own two files,
   --  read from the real host deliberately, into a library at
   --  /opt/landin/lib/landin beside an executable in /opt/landin/bin.
   procedure Add_Firmware_Library (Host : in out Fake_Filesystem);

   overriding function Executable_Directory
     (Host : Fake_Filesystem) return String;

   overriding function Is_Directory
     (Host : Fake_Filesystem; Path : String) return Boolean;

   --  True for a path Add_Link named, and only for one.
   overriding function Is_Link
     (Host : Fake_Filesystem; Path : String) return Boolean;

   procedure Add_Link (Host : in out Fake_Filesystem; Path : String);

   --  Inject an exception at the next read.  An invalid request must return
   --  its diagnostics before this injection can fire.
   procedure Raise_On_Read
     (Host : in out Fake_Filesystem;
      Reason : Ada.Exceptions.Exception_Id := Compiler_Defect'Identity);

   --  Let Reads calls to Read_File finish before injecting.
   procedure Raise_On_Read_After
     (Host : in out Fake_Filesystem; Reads : Natural;
      Reason : Ada.Exceptions.Exception_Id := Compiler_Defect'Identity);

   --  Make every later write answer Not_Writable without retaining bytes.
   --  This pins the driver's output diagnostic without depending on native
   --  filesystem permissions.
   procedure Refuse_Writes (Host : in out Fake_Filesystem);

   procedure Refuse_Removals (Host : in out Fake_Filesystem);

   --  Make the At_Move'th move from now answer Not_Movable, and only it:
   --  a replacement that fails part way, then puts back what it moved.
   procedure Fail_Move (Host : in out Fake_Filesystem; At_Move : Positive);

   overriding procedure Open_Publication
     (Host : Fake_Filesystem; Path : String; Delete_Only : Boolean;
      Root : String;
      Handle : out Landin.Platform.Publication_Handle;
      Stage : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Landin.Platform.Write_Status;
      Reason : out Ada.Strings.Unbounded.Unbounded_String);
   overriding procedure Advance_Publication
     (Host : Fake_Filesystem; Handle : Landin.Platform.Publication_Handle;
      Action : Landin.Platform.Publication_Action;
      Protected_Paths : Landin.Platform.Path_List;
      Protected_Identities : Landin.Platform.Identity_List;
      Status : out Landin.Platform.Write_Status;
      Reason : out Ada.Strings.Unbounded.Unbounded_String);
   --  Both results describe the same actually read object.
   overriding procedure Read_Snapshot
     (Host : Fake_Filesystem; Path : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Identity : out Landin.Platform.File_Identity;
      Status : out Landin.Platform.Read_Status);
   overriding procedure Read_For_Update
     (Host : Fake_Filesystem; Path : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Lease : out Landin.Platform.Update_Handle;
      Status : out Landin.Platform.Read_Status;
      Reason : out Ada.Strings.Unbounded.Unbounded_String);
   overriding procedure Replace_Update
     (Host : Fake_Filesystem; Lease : Landin.Platform.Update_Handle;
      Content : String;
      Status : out Landin.Platform.Write_Status;
      Reason : out Ada.Strings.Unbounded.Unbounded_String);
   overriding function Update_Identity
     (Host : Fake_Filesystem; Lease : Landin.Platform.Update_Handle)
      return Landin.Platform.File_Identity;
   overriding procedure Close_Update
     (Host : Fake_Filesystem; Lease : Landin.Platform.Update_Handle);


   overriding procedure Remove_File
     (Host   : Fake_Filesystem;
      Path   : String;
      Status : out Landin.Platform.Remove_Status);

   overriding procedure Move_File
     (Host   : Fake_Filesystem;
      From, To : String;
      Status : out Landin.Platform.Move_Status);

   --  D558: a directory, unless the path is a file or writes are refused.
   overriding procedure Make_Directory
     (Host   : Fake_Filesystem;
      Path   : String;
      Status : out Landin.Platform.Write_Status);

   --  D526: a private directory is /virtual/tmp/PREFIXn, n counting from
   --  1, until Refuse_Private_Directories; Remove_Tree removes it and
   --  every entry under it, unless Refuse_Removals.
   procedure Refuse_Private_Directories (Host : in out Fake_Filesystem);
   function Private_Directory_Count (Host : Fake_Filesystem) return Natural;

   overriding procedure Make_Private_Directory
     (Host   : Fake_Filesystem;
      Prefix : String;
      Path   : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Landin.Platform.Write_Status);

   overriding procedure Remove_Tree
     (Host   : Fake_Filesystem;
      Path   : String;
      Status : out Landin.Platform.Remove_Status);

   overriding procedure Lock_Output
     (Host : Fake_Filesystem; Path : String; Handle : out Integer);
   overriding procedure Unlock_Output
     (Host : Fake_Filesystem; Handle : Integer);

   overriding procedure Read_File
     (Host    : Fake_Filesystem;
      Path    : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Landin.Platform.Read_Status);

   overriding procedure Write_File
     (Host    : Fake_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Landin.Platform.Write_Status);

   overriding procedure Replace_File
     (Host    : Fake_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Landin.Platform.Write_Status;
      Reason  : out Ada.Strings.Unbounded.Unbounded_String);

   overriding procedure List_Directory
     (Host    : Fake_Filesystem;
      Path    : String;
      Entries : out Landin.Platform.Path_List;
      Status  : out Landin.Platform.List_Status);

   ---------------------------------------------------------------------
   --  Tool runner
   ---------------------------------------------------------------------

   type Fake_Tool_Runner is
     limited new Landin.Platform.Tool_Runner with private;

   procedure Set_Available
     (Host : in out Fake_Tool_Runner; Found : Boolean);

   --  One program the host cannot start while every other one it can, as
   --  a system without the pinned driver but with its distribution's.
   procedure Set_Absent
     (Host : in out Fake_Tool_Runner; Program : String);

   overriding function Available
     (Host : Fake_Tool_Runner; Program : String) return Boolean;

   --  Select a result that every subsequent call returns.  This also
   --  abandons any ordered results that have not yet been consumed.
   --
   --  Ended is defaulted, because almost every case is about a tool that
   --  ran and answered.  A case that wants a program a signal killed says
   --  so, and says nothing about which signal: see `Landin.Platform`.
   procedure Set_Result
     (Host      : in out Fake_Tool_Runner;
      Exit_Code : Integer;
      Output    : String;
      Ended     : Landin.Platform.Termination := Landin.Platform.Exited;
      Error_Output : String := "");

   --  Select ordered mode on the first addition, then append one result for
   --  each expected call.  Running past the end of the script is a compiler
   --  defect rather than an accidental success.
   procedure Add_Result
     (Host      : in out Fake_Tool_Runner;
      Exit_Code : Integer;
      Output    : String;
      Ended     : Landin.Platform.Termination := Landin.Platform.Exited;
      Error_Output : String := "");

   --  Make the next run raise a chosen exception instead of answering,
   --  defaulting to a compiler defect, and only the next. A case that arms
   --  this and then keeps using the runner asks about what happens after
   --  one failure, not about two.
   --
   --  A defect is what a compiler does when it finds itself wrong, so no
   --  source can be relied on to cause one -- every one that could is a
   --  bug to be fixed rather than a case to keep.  Injecting it is how
   --  the driver's promise about a defect is held to: the report a run
   --  had already decided survives it.
   procedure Raise_On_Run
     (Host : in out Fake_Tool_Runner;
      Reason : Ada.Exceptions.Exception_Id := Compiler_Defect'Identity;
      Message : String :=
        "a fake tool was asked to stand in for a compiler defect");

   type Tool_Call is record
      Program   : Ada.Strings.Unbounded.Unbounded_String;
      Arguments : Landin.Platform.Path_List;
      Capture   : Landin.Platform.Capture_Mode := Landin.Platform.Merged;
      --  Run_Attached's, a program `refine run` started, and not a tool.
      Attached  : Boolean := False;
      --  Run_In_Environment's, and the environment it was given.
      Isolated  : Boolean := False;
      Environment : Landin.Platform.Path_List;
   end record;

   function Call_At
     (Host : Fake_Tool_Runner; Index : Positive) return Tool_Call;

   function Last_Command (Host : Fake_Tool_Runner) return String;
   function Run_Count (Host : Fake_Tool_Runner) return Natural;

   overriding function Resolve_Program
     (Host : Fake_Tool_Runner; Program : String) return String;

   overriding procedure Run
     (Host      : Fake_Tool_Runner;
      Program   : String;
      Arguments : Landin.Platform.Path_List;
      Result    : out Landin.Platform.Tool_Result;
      Capture   : Landin.Platform.Capture_Mode := Landin.Platform.Merged);

   --  Answers as Run does, and records the environment it was given.
   overriding procedure Run_In_Environment
     (Host        : Fake_Tool_Runner;
      Program     : String;
      Arguments   : Landin.Platform.Path_List;
      Environment : Landin.Platform.Path_List;
      Result      : out Landin.Platform.Tool_Result;
      Capture     : Landin.Platform.Capture_Mode := Landin.Platform.Merged);

   --  D526: how every later Run_Attached says its program ended: exited
   --  with Exit_Code, or, when Signal is not zero, killed by it.  It
   --  records its call as Run does, and Raise_On_Run applies to it too.
   procedure Set_Program_Result
     (Host        : in out Fake_Tool_Runner;
      Exit_Code   : Integer;
      Signal      : Natural := 0;
      Signal_Name : String := "");

   overriding procedure Run_Attached
     (Host      : Fake_Tool_Runner;
      Program   : String;
      Arguments : Landin.Platform.Path_List;
      Result    : out Landin.Platform.Program_Result);

   --  A fake successful run stands in for writing the requested output.
   --  Cases about a lying tool can turn that promise off.
   procedure Set_Output_Produced
     (Host : in out Fake_Tool_Runner; Produced : Boolean);

   --  Bytes published by a successful fake tool, for post-link consumers.
   procedure Set_Output_Content
     (Host : in out Fake_Tool_Runner; Content : String);

   --  Simulate a zero-exit tool moving the reserved old output back.
   procedure Set_Move_Backup_Back (Host : in out Fake_Tool_Runner);

   overriding function Output_Produced
     (Host : Fake_Tool_Runner; Files : Landin.Platform.Filesystem'Class;
      Path : String) return Boolean;

   overriding procedure Prepare_Output
     (Host : Fake_Tool_Runner; Files : Landin.Platform.Filesystem'Class;
      Path : String);

   --  Which capture mode the last run asked for, so a caller that must
   --  keep the streams apart can be held to it.
   function Last_Capture
     (Host : Fake_Tool_Runner) return Landin.Platform.Capture_Mode;

   ---------------------------------------------------------------------
   --  Channel
   ---------------------------------------------------------------------

   --  Scripted input, read in chunks of at most Chunk bytes so a test can
   --  split a message wherever it likes, and captured output and log.
   --  Pending is whether scripted bytes remain before the next pause, so a
   --  session that sends three edits before a request sees them as one
   --  burst, every time.  A pause is where an editor would wait: Pending
   --  is false there once, and reading goes on past it.
   type Fake_Channel is limited new Landin.Platform.Channel with private;

   procedure Script
     (Host : in out Fake_Channel; Input : String; Chunk : Positive := 4096);

   --  The same for input too long to hold on the stack.
   procedure Script_Unbounded
     (Host  : in out Fake_Channel;
      Input : Ada.Strings.Unbounded.Unbounded_String;
      Chunk : Positive := 4096);

   --  Where the scripted input pauses: byte offsets into it, ascending.
   procedure Pause_At (Host : in out Fake_Channel; Offset : Natural);

   --  Replace a disk file when input resumes after a pause.
   procedure Edit_At
     (Host : in out Fake_Channel; Offset : Natural;
      Files : Fake_Filesystem_Access; Path, Content : String);

   function Output (Host : Fake_Channel) return String;

   function Logged (Host : Fake_Channel) return String;

   overriding procedure Read
     (Host : in out Fake_Channel;
      Into : out String;
      Last : out Natural);

   overriding function Pending (Host : in out Fake_Channel) return Boolean;

   overriding procedure Write (Host : in out Fake_Channel; Item : String);

   overriding procedure Log (Host : in out Fake_Channel; Line : String);

private

   package Unbounded renames Ada.Strings.Unbounded;

   type Entry_Kind is
     (A_File, A_Link, A_Directory, An_Unreadable_File,
      An_Unlistable_Directory);

   type File_Entry is record
      Path    : Unbounded.Unbounded_String;
      Content : Unbounded.Unbounded_String;
      Kind    : Entry_Kind := A_File;
      Identity : Interfaces.Unsigned_64 := 0;
   end record;

   package File_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => File_Entry);

   type List_Call is record
      Path  : Unbounded.Unbounded_String;
      Count : Natural := 0;
   end record;

   package List_Call_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => List_Call);

   type Fake_Publication is record
      Path, Stage, Recovery : Unbounded.Unbounded_String;
      Expected, Fresh : File_Entry;
      Expected_Tree, Fresh_Tree : File_Vectors.Vector;
      Absent, Deletion, Captured, Installed, Finished : Boolean := False;
      Rollback_Pending : Boolean := False;
   end record;
   package Publication_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Fake_Publication);
   type Fake_Update is record
      Path : Unbounded.Unbounded_String;
      Original : File_Entry;
      Closed : Boolean := False;
   end record;
   package Update_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Fake_Update);

   type Store is record
      Files : File_Vectors.Vector;
      Mutation_Armed : Boolean := False;
      Mutation_Action : Landin.Platform.Publication_Action :=
        Landin.Platform.Capture_Previous;
      Mutation_File : File_Entry;
      Publications : Publication_Vectors.Vector;
      Updates : Update_Vectors.Vector;
      --  Latest successful write per path, separate from the live namespace.
      Items : File_Vectors.Vector;
      --  Armed by Raise_On_Read or Raise_On_Read_After and cleared by the
      --  read it fires on, so one arming is one exception.  It lives here
      --  because Read_File takes its host as a constant view.
      Raises       : Boolean := False;
      Reads_Before_Raise : Natural := 0;
      Read_Exception : Ada.Exceptions.Exception_Id :=
        Compiler_Defect'Identity;
      Refuses_Write : Boolean := False;
      Refuses_Removal : Boolean := False;
      Write_Attempts : Natural := 0;
      List_Calls     : List_Call_Vectors.Vector;

      Observed_Path, Observed_Target : Unbounded.Unbounded_String;
      Observations : Natural := 0;
      Next_Identity : Interfaces.Unsigned_64 := 1;
      Output_Is_Locked : Boolean := False;
      Identity_Comparisons : Natural := 0;
      Private_Made : Natural := 0;
      Refuses_Private : Boolean := False;
      --  Fail_Move's: the moves still to come before the failing one.
      Moves_Before_Failure : Natural := 0;
      Fails_Move : Boolean := False;
   end record;

   type Store_Access is access Store;

   --  The constant-view interface needs indirection, with lexical ownership.
   type Store_Owner is new Ada.Finalization.Limited_Controlled with record
      Data : Store_Access := new Store;
   end record;

   overriding procedure Finalize (Owner : in out Store_Owner);

   type Fake_Filesystem is limited new Landin.Platform.Filesystem
   with record
      Uncertain_Identities : Landin.Platform.Path_List;
      Aliases : Landin.Platform.Path_List;
      Links : Landin.Platform.Path_List;
      Executable : Unbounded.Unbounded_String;
      Writes : Store_Owner;
   end record;

   use type Landin.Platform.Tool_Result;

   package Result_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Landin.Platform.Tool_Result);

   package Call_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Tool_Call);

   type Result_Mode is (Repeating, Ordered);

   --  Run is callable on a constant view, so its script cursor and history
   --  live behind an access indirection instead of mutable components.
   type Recorder is record
      Mode        : Result_Mode := Repeating;
      Repeat      : Landin.Platform.Tool_Result;
      Produces_Output : Boolean := True;
      Output_Content : Unbounded.Unbounded_String :=
        Unbounded.To_Unbounded_String ("fake executable");
      Moves_Backup_Back : Boolean := False;
      Output_Store : Store_Access := null;
      Output_Path : Unbounded.Unbounded_String;
      Script      : Result_Vectors.Vector;
      Raises      : Boolean := False;
      Run_Exception : Ada.Exceptions.Exception_Id := Compiler_Defect'Identity;
      Run_Message : Unbounded.Unbounded_String;
      Next_Result : Positive := 1;
      Calls       : Call_Vectors.Vector;
      Program     : Landin.Platform.Program_Result;
   end record;

   type Recorder_Access is access Recorder;

   type Recorder_Owner is new Ada.Finalization.Limited_Controlled with record
      Data : Recorder_Access := new Recorder;
   end record;

   overriding procedure Finalize (Owner : in out Recorder_Owner);

   type Fake_Tool_Runner is limited new Landin.Platform.Tool_Runner
   with record
      State : Recorder_Owner;
      Tool_Available : Boolean := True;
      Absent : Landin.Platform.Path_List;
   end record;

   package Offset_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Natural);

   type Timed_Edit is record
      Offset  : Natural;
      Path    : Unbounded.Unbounded_String;
      Content : Unbounded.Unbounded_String;
   end record;

   package Edit_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Timed_Edit);

   type Fake_Channel is limited new Landin.Platform.Channel with record
      Input  : Unbounded.Unbounded_String;
      Next   : Positive := 1;
      Chunk  : Positive := 4096;
      Pauses : Offset_Vectors.Vector;
      Edits  : Edit_Vectors.Vector;
      Next_Edit : Positive := 1;
      Files  : Fake_Filesystem_Access;
      Output : Unbounded.Unbounded_String;
      Log    : Unbounded.Unbounded_String;
   end record;

end Landin.Testing.Fakes;
