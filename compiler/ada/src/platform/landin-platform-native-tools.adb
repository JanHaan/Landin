with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings.Fixed;

with GNAT.OS_Lib;
with Landin.Platform.Native.Byte_Strings;

with Interfaces.C;
with Interfaces.C.Strings;

package body Landin.Platform.Native.Tools is

   package Unbounded renames Ada.Strings.Unbounded;
   package OS renames GNAT.OS_Lib;
   package C_Strings renames Interfaces.C.Strings;

   use type Ada.Real_Time.Time;
   use type Interfaces.C.int;
   use type Interfaces.C.size_t;
   use type OS.File_Descriptor;
   use type OS.String_Access;

   function Begin_Cancellation return Interfaces.C.int
     with Import, Convention => C,
       External_Name => "landin_cancellation_begin";
   procedure End_Cancellation
     with Import, Convention => C,
       External_Name => "landin_cancellation_end";
   function Pending_Cancellation return Interfaces.C.int
     with Import, Convention => C,
       External_Name => "landin_cancellation_requested";

   procedure Begin_Invocation is
   begin
      if Begin_Cancellation /= 0 then
         raise External_Tool_Failed
           with "could not establish command cancellation";
      end if;
   end Begin_Invocation;

   procedure End_Invocation is
   begin
      End_Cancellation;
   end End_Invocation;

   function Cancellation_Requested return Natural is
     (Natural (Pending_Cancellation));

   --  Host structs and wait/signal constants belong to the C adapter.
   --  The spawn action establishes a private process group before exec.
   function Start_Tool
     (Args    : C_Strings.chars_ptr_array;
      Env     : C_Strings.chars_ptr_array;
      Isolated : Interfaces.C.int;
      Input   : Interfaces.C.int;
      Capture : Interfaces.C.int;
      Errors  : Interfaces.C.int;
      Directory : Interfaces.C.int;
      Child   : access Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C,
       External_Name => "landin_tool_start_in_directory";

   --  Translate C policy refusals without assuming host errno numbers.
   function Process_Start_Error (Error : Interfaces.C.int)
     return C_Strings.chars_ptr
     with Import, Convention => C,
       External_Name => "landin_process_start_error";

   function Start_Failure (Error : Interfaces.C.int; Fallback : String)
     return String;

   function Start_Failure (Error : Interfaces.C.int; Fallback : String)
     return String
   is
      use type C_Strings.chars_ptr;
      Reason : constant C_Strings.chars_ptr := Process_Start_Error (Error);
   begin
      --  GNAT bounds exception messages. Put the corrective action before
      --  any tool path that could consume that bound by itself.
      return (if Reason = C_Strings.Null_Ptr then Fallback
              else C_Strings.Value (Reason) & "; " & Fallback);
   end Start_Failure;

   function Stage_Directory (Text : C_Strings.chars_ptr)
      return Interfaces.C.int
     with Import, Convention => C,
       External_Name => "landin_publication_stage_directory";
   function Rebase_Argument
     (Text : C_Strings.chars_ptr; Directory : Interfaces.C.int;
      Result : out Interfaces.C.char_array; Room : Interfaces.C.size_t)
      return Interfaces.C.int
     with Import, Convention => C,
       External_Name => "landin_publication_rebase_argument";

   function Private_Directory
     (Text : C_Strings.chars_ptr) return Interfaces.C.int
     with Import, Convention => C,
       External_Name => "landin_private_argument_directory";
   function Rebase_Private
     (Text : C_Strings.chars_ptr; Directory : Interfaces.C.int;
      Result : out Interfaces.C.char_array; Room : Interfaces.C.size_t)
      return Interfaces.C.int
     with Import, Convention => C,
       External_Name => "landin_private_rebase_argument";

   function Private_Read_Descriptor
     (Text : Interfaces.C.char_array) return Interfaces.C.int
     with Import, Convention => C,
       External_Name => "landin_private_read_descriptor";
   function Private_Path_Current
     (Text : Interfaces.C.char_array) return Interfaces.C.int
     with Import, Convention => C,
       External_Name => "landin_private_path_current";

   --  Creates one capture file in the host's temporary directory and
   --  returns its descriptor, or -1, with its NUL-terminated name in Path.
   function Create_Capture
     (Path     : out Interfaces.C.char_array;
      Capacity : Interfaces.C.size_t) return Interfaces.C.int
     with Import, Convention => C, External_Name => "landin_tool_capture";

   function Read_Capture
     (FD : Interfaces.C.int; Bytes : out C_Strings.chars_ptr;
      Size : out Interfaces.C.size_t) return Interfaces.C.int
     with Import, Convention => C,
       External_Name => "landin_tool_capture_read";
   procedure Free_Capture (Bytes : C_Strings.chars_ptr)
     with Import, Convention => C,
       External_Name => "landin_tool_capture_free";
   function Close_Capture
     (FD : Interfaces.C.int; Reason : out Interfaces.C.char_array;
      Room : Interfaces.C.size_t) return Interfaces.C.int
     with Import, Convention => C,
       External_Name => "landin_tool_capture_close";

   procedure Capture_Bytes
     (FD : OS.File_Descriptor; Content : out Unbounded.Unbounded_String);
   procedure Capture_Bytes
     (FD : OS.File_Descriptor; Content : out Unbounded.Unbounded_String)
   is
      Bytes : C_Strings.chars_ptr := C_Strings.Null_Ptr;
      Size : Interfaces.C.size_t;
   begin
      if Read_Capture (Interfaces.C.int (FD), Bytes, Size) /= 0 then
         raise External_Tool_Failed with "could not read retained tool output";
      end if;
      begin
         Content := Byte_Strings.Copy (Bytes, Size);
      exception
         when others =>
            Free_Capture (Bytes);
            raise;
      end;
      Free_Capture (Bytes);
   end Capture_Bytes;

   --  Not GNAT.OS_Lib's temporary files: those are created relative to the
   --  current directory whatever TMPDIR says, so every capture landed beside
   --  the caller's sources and a read-only directory refused every tool.
   procedure Create_Capture_File
     (FD   : out OS.File_Descriptor;
      Name : out OS.String_Access);

   procedure Create_Capture_File
     (FD   : out OS.File_Descriptor;
      Name : out OS.String_Access)
   is
      Path   : Interfaces.C.char_array (0 .. 4095);
      Opened : constant Interfaces.C.int :=
        Create_Capture (Path, Path'Length);
   begin
      if Opened < 0 then
         FD := OS.Invalid_FD;
         Name := null;
      else
         FD := OS.File_Descriptor (Opened);
         Name := new String'(Interfaces.C.To_Ada (Path));
      end if;
   end Create_Capture_File;

   function Wait_Tool
     (Child   : Interfaces.C.int;
      Status  : access Interfaces.C.int;
      No_Hang : Interfaces.C.int;
      Owned   : access Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C,
       External_Name => "landin_tool_wait_reserved";

   function Stop_Tool
     (Child  : Interfaces.C.int;
      Status : access Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "landin_tool_stop";

   function Cancel_Tool
     (Child : Interfaces.C.int; Status : access Interfaces.C.int)
      return Interfaces.C.int
     with Import, Convention => C, External_Name => "landin_tool_cancel";

   function Start_Program
     (Args          : C_Strings.chars_ptr_array;
      Signal_Number : access Interfaces.C.int;
      Status        : access Interfaces.C.int;
      Child         : access Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "landin_program_run";

   function Signal_Name (Number : Interfaces.C.int)
     return C_Strings.chars_ptr
     with Import, Convention => C, External_Name => "landin_signal_name";

   overriding procedure Run_Attached
     (Host      : Native_Tool_Runner;
      Program   : String;
      Arguments : Path_List;
      Result    : out Program_Result)
   is
      pragma Unreferenced (Host);
      use type C_Strings.chars_ptr;
      List : C_Strings.chars_ptr_array
        (0 .. Interfaces.C.size_t (Arguments.Length) + 1) :=
          [others => C_Strings.Null_Ptr];
      Signal_Number : aliased Interfaces.C.int := 0;
      Status : aliased Interfaces.C.int := 0;
      Child : aliased Interfaces.C.int := 0;
      Error : Interfaces.C.int;
   begin
      Result := (others => <>);
      if Private_Path_Current (Interfaces.C.To_C (Program)) = 0 then
         raise External_Tool_Failed
           with "private program directory changed before launch: " & Program
             & "; rerun to compile in a fresh private directory";
      end if;
      --  Execution is still pathname based after this observed-change
      --  refusal. It is not a pinned executable-object guarantee.
      List (0) := C_Strings.New_String (Program);
      for Index in 1 .. Natural (Arguments.Length) loop
         List (Interfaces.C.size_t (Index)) :=
           C_Strings.New_String (Arguments.Element (Index));
      end loop;
      Error := Start_Program
        (List, Signal_Number'Access, Status'Access, Child'Access);
      for Item of List loop
         C_Strings.Free (Item);
      end loop;
      if Error /= 0 then
         raise External_Tool_Failed
           with Start_Failure
             (Error, (if Child = 0 then "cannot start "
                      else "cannot wait for ") & Program);
      elsif Signal_Number /= 0 then
         Result.Ended := Signaled;
         Result.Signal := Natural (Signal_Number);
         declare
            Name : constant C_Strings.chars_ptr := Signal_Name (Signal_Number);
         begin
            Result.Signal_Name := Unbounded.To_Unbounded_String
              (if Name = C_Strings.Null_Ptr then "signal"
               else C_Strings.Value (Name));
         end;
      else
         Result.Exit_Code := Integer (Status);
      end if;
   end Run_Attached;

   procedure Set_Limit
     (Host : in out Native_Tool_Runner; Seconds : Duration) is
   begin
      Host.Limit := Seconds;
   end Set_Limit;

   procedure Set_Input (Host : in out Native_Tool_Runner; Path : String) is
   begin
      Host.Input := Unbounded.To_Unbounded_String (Path);
   end Set_Input;

   overriding function Available
     (Host : Native_Tool_Runner; Program : String) return Boolean
   is
      pragma Unreferenced (Host);
      Located : OS.String_Access := OS.Locate_Exec_On_Path (Program);
      Found : constant Boolean := Located /= null;
   begin
      OS.Free (Located);
      return Found;
   end Available;

   overriding function Resolve_Program
     (Host : Native_Tool_Runner; Program : String) return String
   is
      pragma Unreferenced (Host);
      Located : OS.String_Access := OS.Locate_Exec_On_Path (Program);
   begin
      if Located = null then
         return "";
      end if;
      declare
         Path : constant String :=
           OS.Normalize_Pathname (Located.all, Resolve_Links => False);
      begin
         OS.Free (Located);
         return Path;
      end;
   end Resolve_Program;

   --  Run, with the caller's environment unless Isolated, and then with
   --  exactly the variables Environment names (D821).
   procedure Run_Tool
     (Host        : Native_Tool_Runner;
      Program     : String;
      Arguments   : Path_List;
      Environment : Path_List;
      Isolated    : Boolean;
      Result      : out Tool_Result;
      Capture     : Capture_Mode);

   procedure Run_Tool
     (Host        : Native_Tool_Runner;
      Program     : String;
      Arguments   : Path_List;
      Environment : Path_List;
      Isolated    : Boolean;
      Result      : out Tool_Result;
      Capture     : Capture_Mode)
   is
      List           : C_Strings.chars_ptr_array
        (0 .. Interfaces.C.size_t (Arguments.Length) + 1) :=
          [others => C_Strings.Null_Ptr];
      Env_List       : C_Strings.chars_ptr_array
        (0 .. Interfaces.C.size_t (Environment.Length)) :=
          [others => C_Strings.Null_Ptr];
      Located        : OS.String_Access := null;
      Name           : OS.String_Access := null;
      FD             : OS.File_Descriptor := OS.Invalid_FD;
      Error_Name     : OS.String_Access := null;
      Error_FD       : OS.File_Descriptor := OS.Invalid_FD;
      Input_FD       : OS.File_Descriptor := OS.Invalid_FD;
      Directory_FD   : OS.File_Descriptor := OS.Invalid_FD;
      Status         : aliased Interfaces.C.int := 0;
      Pid            : aliased Interfaces.C.int := 0;
      Exceeded_Limit : Boolean := False;
      Cancelled      : Boolean := False;
      Start_Error    : Interfaces.C.int;
      Child_Owned    : aliased Interfaces.C.int := 0;


      function Rebased (Argument : String) return String;

      function Rebased (Argument : String) return String is
         Text : C_Strings.chars_ptr := C_Strings.New_String (Argument);
         Buffer, Private_Buffer :
           Interfaces.C.char_array (0 .. Argument'Length);
         Answer : Interfaces.C.int;
         Intermediate : C_Strings.chars_ptr;
      begin
         if Directory_FD = OS.Invalid_FD then
            C_Strings.Free (Text);
            return Argument;
         end if;
         Answer := Rebase_Argument
           (Text, Interfaces.C.int (Directory_FD), Buffer, Buffer'Length);
         C_Strings.Free (Text);
         if Answer /= 0 then
            raise External_Tool_Failed
              with "tool outputs span incompatible staging directories";
         end if;
         Intermediate := C_Strings.New_String (Interfaces.C.To_Ada (Buffer));
         Answer := Rebase_Private
           (Intermediate, Interfaces.C.int (Directory_FD), Private_Buffer,
            Private_Buffer'Length);
         C_Strings.Free (Intermediate);
         if Answer /= 0 then
            raise External_Tool_Failed
              with "tool inputs span incompatible private directories;"
                & " keep generated inputs in one private workspace";
         end if;
         return Interfaces.C.To_Ada (Private_Buffer);
      end Rebased;

      procedure Stop_Child;

      procedure Stop_Child is
      begin
         if Pid > 0 then
            if Stop_Tool (Pid, Status'Access) /= Pid then
               raise External_Tool_Failed
                 with "could not stop tool process group: " & Program;
            end if;
            Pid := 0;
         end if;
      end Stop_Child;

      procedure Release_Arguments;

      procedure Release_Arguments is
      begin
         for Item of List loop
            C_Strings.Free (Item);
         end loop;
         for Item of Env_List loop
            C_Strings.Free (Item);
         end loop;
         OS.Free (Located);
      end Release_Arguments;

      procedure Cleanup_Capture;

      procedure Cleanup_Capture is
         Clean : Boolean := True;
         Closed_Input : Boolean := True;
         Reason : Unbounded.Unbounded_String;
         procedure Remove
           (File : in out OS.File_Descriptor;
            Path : in out OS.String_Access);
         procedure Remove
           (File : in out OS.File_Descriptor;
            Path : in out OS.String_Access)
         is
            Message : Interfaces.C.char_array (0 .. 16383);
            Room : constant Interfaces.C.size_t := Message'Length;
         begin
            if File /= OS.Invalid_FD then
               if Close_Capture
                 (Interfaces.C.int (File), Message, Room) /= 0
               then
                  Clean := False;
                  Unbounded.Append
                    (Reason, Interfaces.C.To_Ada (Message) & "; ");
               end if;
               File := OS.Invalid_FD;
            end if;
            OS.Free (Path);
         end Remove;
      begin
         Remove (FD, Name);
         Remove (Error_FD, Error_Name);
         if Input_FD /= OS.Invalid_FD then
            OS.Close (Input_FD, Closed_Input);
            Clean := Clean and Closed_Input;
            Input_FD := OS.Invalid_FD;
         end if;
         if Directory_FD /= OS.Invalid_FD then
            OS.Close (Directory_FD, Closed_Input);
            Clean := Clean and Closed_Input;
            Directory_FD := OS.Invalid_FD;
         end if;
         if not Clean then
            raise External_Tool_Failed
              with "could not release temporary tool output: "
                & Unbounded.To_String (Reason);
         end if;
      end Cleanup_Capture;

   begin
      Result := (Ended     => Landin.Platform.Exited,
                 Exit_Code => 0,
                 Output    => Unbounded.Null_Unbounded_String,
                 Error_Output => Unbounded.Null_Unbounded_String);
      if Cancellation_Requested /= 0 then
         Result.Ended := Landin.Platform.Signaled;
         Result.Output := Unbounded.To_Unbounded_String
           ("refine: command cancelled before starting " & Program
            & ASCII.LF);
         return;
      end if;
      Located := OS.Locate_Exec_On_Path (Program);

      if Located = null then
         raise External_Tool_Failed
           with "tool not found on PATH: " & Program;
      end if;

      for Argument of Arguments loop
         declare
            Text : C_Strings.chars_ptr := C_Strings.New_String (Argument);
            Selected : Interfaces.C.int := Stage_Directory (Text);
            Closed : Boolean;
            Duplicate : OS.File_Descriptor;
         begin
            if Selected = -1 then
               Selected := Private_Directory (Text);
            end if;
            C_Strings.Free (Text);
            if Selected = -2 then
               raise External_Tool_Failed
                 with "cannot pin tool output staging directory";
            elsif Selected >= 0 then
               if Directory_FD = OS.Invalid_FD then
                  Directory_FD := OS.File_Descriptor (Selected);
               else
                  Duplicate := OS.File_Descriptor (Selected);
                  OS.Close (Duplicate, Closed);
                  if not Closed then
                     raise External_Tool_Failed
                       with "cannot close output staging directory";
                  end if;
               end if;
            end if;
         end;
      end loop;

      List (0) := C_Strings.New_String
        (OS.Normalize_Pathname (Located.all, Resolve_Links => False));
      for Index in 1 .. Natural (Arguments.Length) loop
         List (Interfaces.C.size_t (Index)) :=
           C_Strings.New_String (Rebased (Arguments.Element (Index)));
      end loop;
      declare
         Next : Interfaces.C.size_t := 0;
      begin
         for Item of Environment loop
            if Ada.Strings.Fixed.Index (Item, "=") /= 0 then
               Env_List (Next) := C_Strings.New_String (Item);
               Next := Next + 1;
            elsif Ada.Environment_Variables.Exists (Item) then
               Env_List (Next) := C_Strings.New_String
                 (Item & "=" & Ada.Environment_Variables.Value (Item));
               Next := Next + 1;
            end if;
         end loop;
      end;

      --  The adapter chooses a unique name and creates the file before
      --  returning. Pass that open descriptor to the spawn action, avoiding
      --  a second filename lookup before the child captures output.
      Create_Capture_File (FD, Name);

      if FD = OS.Invalid_FD or else Name = null then
         raise External_Tool_Failed
           with "could not create temporary tool output";
      end if;

      if Capture = Output_Only then
         Create_Capture_File (Error_FD, Error_Name);
         if Error_FD = OS.Invalid_FD or else Error_Name = null then
            raise External_Tool_Failed
              with "could not create temporary tool error output";
         end if;
      end if;

      --  Opened here, before the tool starts, so that an input which is
      --  not there is the caller's fault and not the tool's.
      if Unbounded.Length (Host.Input) > 0 then
         Input_FD := OS.File_Descriptor (Private_Read_Descriptor
           (Interfaces.C.To_C (Unbounded.To_String (Host.Input))));
         if Input_FD = -2 then
            Input_FD := OS.Open_Read
              (Unbounded.To_String (Host.Input), OS.Binary);
         end if;
         if Input_FD = OS.Invalid_FD then
            raise External_Tool_Failed
              with "could not open standard input: "
                   & Unbounded.To_String (Host.Input);
         end if;
      end if;

      declare
         Deadline : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Host.Limit);
         Reaped : Interfaces.C.int := 0;
         Wait_Interval : Duration := 0.001;
      begin
         Start_Error := Start_Tool
           (List, Env_List, (if Isolated then 1 else 0),
            (if Input_FD = OS.Invalid_FD then -1
             else Interfaces.C.int (Input_FD)),
            Interfaces.C.int (FD),
            (if Capture = Merged then -1 else Interfaces.C.int (Error_FD)),
            (if Directory_FD = OS.Invalid_FD then -1
             else Interfaces.C.int (Directory_FD)),
            Pid'Access);
         if Start_Error /= 0 then
            raise External_Tool_Failed
              with Start_Failure
                (Start_Error, "could not run tool: " & Program);
         end if;

         --  Keep both descriptors: captures are anonymous, and reading
         --  after the child exits must not resolve a temporary pathname.
         Exceeded_Limit := False;
         loop
            if Cancellation_Requested /= 0 then
               if Cancel_Tool (Pid, Status'Access) /= Pid then
                  raise External_Tool_Failed
                    with "could not stop cancelled tool: " & Program;
               end if;
               Pid := 0;
               Cancelled := True;
               exit;
            end if;
            Reaped :=
              Wait_Tool
                (Pid, Status'Access, No_Hang => 1,
                 Owned => Child_Owned'Access);
            if Child_Owned = 0 then
               Pid := 0;
            end if;
            exit when Reaped /= 0;
            if Ada.Real_Time.Clock > Deadline then
               Stop_Child;
               Exceeded_Limit := True;
               exit;
            end if;
            --  Check shortly after spawning: a tool that exits just after
            --  the first poll should not wait for the long-running cadence.
            delay Wait_Interval;
            Wait_Interval := Duration'Min (Wait_Interval * 2, 0.02);
         end loop;

         if Reaped < 0 then
            raise External_Tool_Failed
              with "could not wait for tool: " & Program;
         end if;

         Pid := 0;
      end;

      Capture_Bytes (FD, Result.Output);
      if Error_FD /= OS.Invalid_FD then
         Capture_Bytes (Error_FD, Result.Error_Output);
      end if;
      if Exceeded_Limit then
         Unbounded.Append
           (Result.Output,
            "landin: " & Program & " ran longer than the limit of"
            & Duration'Image (Host.Limit) & " seconds and was stopped"
            & ASCII.LF);
      end if;
      if Cancelled then
         Unbounded.Append
           (Result.Output,
            "refine: command cancelled; tool stopped: " & Program
            & ASCII.LF);
      end if;

      --  The host adapter decodes wait status using the host's macros:
      --  an ordinary exit retains its status; signal termination is -1.
      --  The native platform cases check both outcomes on each host.
      --
      --  A watchdog kill has the same POSIX wait status as another signal,
      --  so Exceeded_Limit takes precedence over that decoding.  No signal
      --  number reaches the record; [1960] says which signal is not stable
      --  program behaviour, and this seam is where that stops.
      if Exceeded_Limit then
         Result.Ended := Landin.Platform.Timed_Out;
         Result.Exit_Code := 0;
      elsif Cancelled or else Status = -1 then
         Result.Ended := Landin.Platform.Signaled;
         Result.Exit_Code := 0;
      else
         Result.Ended := Landin.Platform.Exited;
         Result.Exit_Code := Integer (Status);
      end if;

      Cleanup_Capture;
      Release_Arguments;
   exception
      when Failure : others =>
         declare
            Notes : Unbounded.Unbounded_String;
         begin
            begin
               Stop_Child;
            exception
               when Cleanup : others =>
                  Unbounded.Append
                    (Notes, Ada.Exceptions.Exception_Message (Cleanup) & "; ");
            end;
            begin
               Cleanup_Capture;
            exception
               when Cleanup : others =>
                  Unbounded.Append
                    (Notes, Ada.Exceptions.Exception_Message (Cleanup) & "; ");
            end;
            Release_Arguments;
            if Unbounded.Length (Notes) > 0 then
               Ada.Exceptions.Raise_Exception
                 (Ada.Exceptions.Exception_Identity (Failure),
                  Ada.Exceptions.Exception_Message (Failure) & "; cleanup: "
                  & Unbounded.To_String (Notes));
            end if;
         end;
         raise;
   end Run_Tool;

   overriding procedure Run
     (Host      : Native_Tool_Runner;
      Program   : String;
      Arguments : Path_List;
      Result    : out Tool_Result;
      Capture   : Capture_Mode := Merged) is
   begin
      Run_Tool (Host, Program, Arguments, No_Arguments, False, Result,
                Capture);
   end Run;

   overriding procedure Run_In_Environment
     (Host        : Native_Tool_Runner;
      Program     : String;
      Arguments   : Path_List;
      Environment : Path_List;
      Result      : out Tool_Result;
      Capture     : Capture_Mode := Merged) is
   begin
      Run_Tool (Host, Program, Arguments, Environment, True, Result,
                Capture);
   end Run_In_Environment;

   overriding function Output_Produced
     (Host : Native_Tool_Runner; Files : Filesystem'Class; Path : String)
      return Boolean
   is
      pragma Unreferenced (Host);
   begin
      return Files.Exists (Path) and then not Files.Is_Directory (Path);
   end Output_Produced;

   overriding procedure Prepare_Output
     (Host : Native_Tool_Runner; Files : Filesystem'Class; Path : String)
   is
      pragma Unreferenced (Host, Files, Path);
   begin
      null;
   end Prepare_Output;

end Landin.Platform.Native.Tools;
