--  Test doubles for the host.
--
--  An in-memory filesystem and a scripted tool runner.  The suite must be
--  able to prove what the compiler does with an unreadable file or a failing
--  linker without arranging one on the machine running the tests.

with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Landin.Platform;

package Landin.Testing.Fakes is

   type Fake_Filesystem is limited new Landin.Platform.Filesystem with private;

   procedure Add_File
     (Host : in out Fake_Filesystem; Path : String; Content : String);

   --  A path that exists, can be listed, and cannot be read as a file.
   procedure Add_Directory (Host : in out Fake_Filesystem; Path : String);

   --  A path that exists and refuses to be read, which is how the driver's
   --  unreadable-source diagnostic gets tested.
   procedure Add_Unreadable (Host : in out Fake_Filesystem; Path : String);

   function Written (Host : Fake_Filesystem; Path : String) return String;

   overriding function Exists
     (Host : Fake_Filesystem; Path : String) return Boolean;

   overriding function Is_Directory
     (Host : Fake_Filesystem; Path : String) return Boolean;

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

   --  Select a result that every subsequent call returns.  This also
   --  abandons any ordered results that have not yet been consumed.
   procedure Set_Result
     (Host      : in out Fake_Tool_Runner;
      Exit_Code : Integer;
      Output    : String);

   --  Select ordered mode on the first addition, then append one result for
   --  each expected call.  Running past the end of the script is a compiler
   --  defect rather than an accidental success.
   procedure Add_Result
     (Host      : in out Fake_Tool_Runner;
      Exit_Code : Integer;
      Output    : String);

   type Tool_Call is record
      Program   : Ada.Strings.Unbounded.Unbounded_String;
      Arguments : Landin.Platform.Path_List;
      Capture   : Landin.Platform.Capture_Mode := Landin.Platform.Merged;
   end record;

   function Call_At
     (Host : Fake_Tool_Runner; Index : Positive) return Tool_Call;

   function Last_Command (Host : Fake_Tool_Runner) return String;
   function Run_Count (Host : Fake_Tool_Runner) return Natural;

   overriding procedure Run
     (Host      : Fake_Tool_Runner;
      Program   : String;
      Arguments : Landin.Platform.Path_List;
      Result    : out Landin.Platform.Tool_Result;
      Capture   : Landin.Platform.Capture_Mode := Landin.Platform.Merged);

   --  Which capture mode the last run asked for, so a caller that must
   --  keep the streams apart can be held to it.
   function Last_Capture
     (Host : Fake_Tool_Runner) return Landin.Platform.Capture_Mode;

private

   package Unbounded renames Ada.Strings.Unbounded;

   type Entry_Kind is (A_File, A_Directory, An_Unreadable_File);

   type File_Entry is record
      Path    : Unbounded.Unbounded_String;
      Content : Unbounded.Unbounded_String;
      Kind    : Entry_Kind := A_File;
   end record;

   package File_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => File_Entry);

   type Store is record
      Items : File_Vectors.Vector;
   end record;

   type Store_Access is access Store;

   type Fake_Filesystem is limited new Landin.Platform.Filesystem
   with record
      Items  : File_Vectors.Vector;
      Writes : Store_Access := new Store;
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
      Script      : Result_Vectors.Vector;
      Next_Result : Positive := 1;
      Calls       : Call_Vectors.Vector;
   end record;

   type Recorder_Access is access Recorder;

   type Fake_Tool_Runner is limited new Landin.Platform.Tool_Runner
   with record
      State : Recorder_Access := new Recorder;
   end record;

end Landin.Testing.Fakes;
