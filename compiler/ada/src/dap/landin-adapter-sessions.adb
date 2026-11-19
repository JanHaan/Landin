with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Indefinite_Vectors;
with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;
with Ada.Calendar;
with Ada.Exceptions;
with Interfaces;
with Landin.Adapter.MI;
with Landin.Json;
with Landin.Server.Transport;
with Landin.Site_Tables;

package body Landin.Adapter.Sessions is

   package US renames Ada.Strings.Unbounded;
   package J renames Landin.Json;
   package P renames Landin.Platform;
   package Transport renames Landin.Server.Transport;
   use type US.Unbounded_String;
   use type J.Value_Kind;
   use type Ada.Calendar.Time;
   use type Landin.Adapter.MI.Record_Kind;
   use type Landin.Site_Tables.Answer_Kind;
   use type Transport.Status;

   --  The namespaces a library file is recorded under (D422).
   type Namespace_Index is range 1 .. 3;
   Namespaces : constant array (Namespace_Index) of access constant String :=
     [new String'("core"), new String'("hosted"), new String'("platform")];
   Recorded_Prefix : constant String := "/landin-library/";

   --  How long one answer of a debugger may take.  A run or a step is
   --  answered when it starts, so only the debugger's own work counts.
   Answer_Limit : constant Duration := 60.0;

   --  How long a debugger may take to end once its input is closed.
   Stop_Grace : constant Duration := 5.0;

   function Starts_With (Item, Prefix : String) return Boolean is
     (Item'Length >= Prefix'Length
      and then Item (Item'First .. Item'First + Prefix'Length - 1) = Prefix);

   function Image (Value : Long_Long_Integer) return String is
     (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));

   function Image (Value : Integer) return String is
     (Image (Long_Long_Integer (Value)));

   function Debugger_For (Header : String) return Debugger_Kind is
      function Byte (Offset : Natural) return Natural is
        (if Header'Length > Offset
         then Character'Pos (Header (Header'First + Offset)) else 256);
   begin
      if Header'Length >= 4
        and then Byte (0) in 16#CF# | 16#CE# and then Byte (1) = 16#FA#
        and then Byte (2) = 16#ED# and then Byte (3) = 16#FE#
      then
         return LLDB;
      elsif Header'Length >= 8 and then Byte (0) = 16#7F#
        and then Header (Header'First + 1 .. Header'First + 3) = "ELF"
        and then Byte (7) = 9
      then
         --  EI_OSABI 9, ELFOSABI_FREEBSD.
         return LLDB;
      end if;
      return GDB;
   end Debugger_For;

   function Local_Path (Recorded, Library : String) return String is
   begin
      if Library /= "" and then Starts_With (Recorded, Recorded_Prefix) then
         for Name of Namespaces loop
            declare
               Prefix : constant String := Recorded_Prefix & Name.all & "/";
            begin
               if Starts_With (Recorded, Prefix) then
                  return Library & "/" & Name.all & "/"
                    & Recorded (Recorded'First + Prefix'Length
                                .. Recorded'Last);
               end if;
            end;
         end loop;
      end if;
      return Recorded;
   end Local_Path;

   function Recorded_Path (Local, Library : String) return String is
   begin
      if Library /= "" then
         for Name of Namespaces loop
            declare
               Prefix : constant String := Library & "/" & Name.all & "/";
            begin
               if Starts_With (Local, Prefix) then
                  return Recorded_Prefix & Name.all & "/"
                    & Local (Local'First + Prefix'Length .. Local'Last);
               end if;
            end;
         end loop;
      end if;
      return Local;
   end Recorded_Path;

   ---------------------------------------------------------------------
   --  Reading JSON
   ---------------------------------------------------------------------

   function Text_Of
     (D : J.Document; Item : J.Value; Name : String) return String;
   function Text_Of
     (D : J.Document; Item : J.Value; Name : String) return String
   is
      Found : constant J.Value := J.Member (D, Item, Name);
   begin
      return (if J.Is_Kind (D, Found, J.String_Value)
                or else J.Is_Kind (D, Found, J.Number_Value)
              then J.Text (D, Found) else "");
   end Text_Of;

   --  A natural number written as a JSON integer or as MI's decimal or
   --  0x string, or -1.
   function Number (Text : String) return Long_Long_Integer;
   function Number (Text : String) return Long_Long_Integer is
      Sixteen : constant Boolean :=
        Text'Length > 2 and then Text (Text'First .. Text'First + 1) = "0x";
      First : constant Positive :=
        (if Sixteen then Text'First + 2 else Text'First);
      Value : Long_Long_Integer := 0;
   begin
      if Text'Length = 0 or else First > Text'Last then
         return -1;
      end if;
      for C of Text (First .. Text'Last) loop
         declare
            Digit : constant Integer :=
              (if C in '0' .. '9' then Character'Pos (C) - Character'Pos ('0')
               elsif Sixteen and then C in 'a' .. 'f'
               then Character'Pos (C) - Character'Pos ('a') + 10
               elsif Sixteen and then C in 'A' .. 'F'
               then Character'Pos (C) - Character'Pos ('A') + 10
               else -1);
         begin
            if Digit < 0 or else Value > 2 ** 52 then
               return -1;
            end if;
            Value := Value * (if Sixteen then 16 else 10)
              + Long_Long_Integer (Digit);
         end;
      end loop;
      return Value;
   end Number;

   function Number_Of
     (D : J.Document; Item : J.Value; Name : String) return Long_Long_Integer
   is (Number (Text_Of (D, Item, Name)));

   --  GDB writes an exit status in octal; 1 for what is not one.
   function Octal (Written : String) return Long_Long_Integer;
   function Octal (Written : String) return Long_Long_Integer is
      Value : Long_Long_Integer := 0;
   begin
      if Written = "" or else Written'Length > 6
        or else (for some C of Written => C not in '0' .. '7')
      then
         return 1;
      end if;
      for C of Written loop
         Value := Value * 8 + Long_Long_Integer
           (Character'Pos (C) - Character'Pos ('0'));
      end loop;
      return Value;
   end Octal;

   function Text_Of_Element
     (D : J.Document; Item : J.Value; Position : Positive) return String;
   function Text_Of_Element
     (D : J.Document; Item : J.Value; Position : Positive) return String
   is
      Found : constant J.Value := J.Element (D, Item, Position);
   begin
      return (if J.Is_Kind (D, Found, J.String_Value)
              then J.Text (D, Found) else "");
   end Text_Of_Element;

   function Flag_Of
     (D : J.Document; Item : J.Value; Name : String) return Boolean
   is (J.Is_Kind (D, J.Member (D, Item, Name), J.True_Value));

   ---------------------------------------------------------------------
   --  The session's state
   ---------------------------------------------------------------------

   package Text_Vectors is new Ada.Containers.Indefinite_Vectors
     (Positive, String);

   package Text_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => String, Hash => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   --  What a variables reference stands for: a frame's locals, an
   --  expression in a frame whose GDB variable object is not made yet,
   --  or a variable object whose children are asked for.
   type Reference_Kind is (Frame_Locals, Expression, Variable_Object);

   type Reference is record
      Kind   : Reference_Kind := Frame_Locals;
      Thread : Natural := 0;
      Level  : Natural := 0;
      Name   : US.Unbounded_String;
   end record;

   package Reference_Vectors is new Ada.Containers.Vectors
     (Positive, Reference);

   --  A relayed request: the editor's sequence number and its command.
   type Relayed is record
      Client_Seq : Long_Long_Integer := 0;
      Command    : US.Unbounded_String;
      Ours       : Boolean := False;
   end record;

   package Relay_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Relayed, Hash => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   Debugger_Ended : exception;
   No_Answer : exception;

   --  A frame identifier: the thread and the frame's level.
   Frame_Stride : constant := 100_000;

   type Session_State
     (Client   : not null access P.Channel'Class;
      Debugger : not null access P.Debugger_Session'Class)
   is tagged limited record
      Started      : Boolean := False;
      Kind         : Debugger_Kind := GDB;
      Attached     : Boolean := False;
      Stop_On_Entry : Boolean := False;
      Configured   : Boolean := False;
      Finished     : Boolean := False;
      Program      : US.Unbounded_String;
      Library      : US.Unbounded_String;
      Out_Seq      : Long_Long_Integer := 0;
      Client_Reader : Transport.Reader;
      --  The editor's `initialize` arguments, for lldb-dap.
      Initialize   : US.Unbounded_String :=
        US.To_Unbounded_String ("{}");
      --  GDB: bytes read and not yet a whole line, the token of the next
      --  command, and the records that arrived while a command waited.
      Buffer       : US.Unbounded_String;
      Next_Token   : Natural := 0;
      Pending      : Text_Vectors.Vector;
      Breakpoints  : Text_Maps.Map;
      References   : Reference_Vectors.Vector;
      Objects      : Text_Vectors.Vector;
      Pause_Asked  : Boolean := False;
      --  LLDB: the relay's reader and its requests in flight.
      Relay_Reader : Transport.Reader;
      Relay_Seq    : Long_Long_Integer := 0;
      In_Flight    : Relay_Maps.Map;
      Relay_Queue  : Text_Vectors.Vector;
      --  The last stop's panic, or "".
      Panic        : US.Unbounded_String;
      Panic_Kind   : US.Unbounded_String;
   end record;

   ---------------------------------------------------------------------
   --  The debugger's output as a channel, for the relay's framing
   ---------------------------------------------------------------------

   type Debugger_Channel (S : not null access Session_State) is
     limited new P.Channel with null record;

   overriding procedure Read
     (Host : in out Debugger_Channel; Into : out String; Last : out Natural);
   overriding function Pending (Host : in out Debugger_Channel)
     return Boolean;
   overriding procedure Write (Host : in out Debugger_Channel; Item : String);
   overriding procedure Log (Host : in out Debugger_Channel; Line : String);

   overriding procedure Read
     (Host : in out Debugger_Channel; Into : out String; Last : out Natural)
   is
   begin
      Host.S.Debugger.Read (P.Debugger, Into, Last);
   end Read;

   overriding function Pending (Host : in out Debugger_Channel)
     return Boolean
   is
      Ready : P.Ready_Streams;
   begin
      Host.S.Debugger.Wait (Host.S.Client.all, 0.0, Ready);
      return Ready (P.Debugger);
   end Pending;

   overriding procedure Write (Host : in out Debugger_Channel; Item : String)
   is
      Sent : Boolean;
   begin
      Host.S.Debugger.Send (Item, Sent);
      if not Sent then
         raise Debugger_Ended;
      end if;
   end Write;

   overriding procedure Log (Host : in out Debugger_Channel; Line : String)
   is null;

   ---------------------------------------------------------------------
   --  Writing to the editor
   ---------------------------------------------------------------------

   procedure Emit (S : in out Session_State; Item : String);
   procedure Emit (S : in out Session_State; Item : String) is
   begin
      S.Client.Write (Transport.Framed (Item));
   end Emit;

   function Next_Seq (S : in out Session_State) return Long_Long_Integer;
   function Next_Seq (S : in out Session_State) return Long_Long_Integer is
   begin
      S.Out_Seq := S.Out_Seq + 1;
      return S.Out_Seq;
   end Next_Seq;

   procedure Respond
     (S : in out Session_State; Request_Seq : Long_Long_Integer;
      Command : String; Success : Boolean; Message : String := "";
      Body_Of : String := "");
   procedure Respond
     (S : in out Session_State; Request_Seq : Long_Long_Integer;
      Command : String; Success : Boolean; Message : String := "";
      Body_Of : String := "")
   is
      B : J.Builder;
   begin
      J.Begin_Object (B);
      J.Name (B, "seq");
      J.Write_Integer (B, Next_Seq (S));
      J.Name (B, "type");
      J.Write_String (B, "response");
      J.Name (B, "request_seq");
      J.Write_Integer (B, Request_Seq);
      J.Name (B, "success");
      J.Write_Boolean (B, Success);
      J.Name (B, "command");
      J.Write_String (B, Command);
      if Message /= "" then
         J.Name (B, "message");
         J.Write_String (B, Message);
      end if;
      if Body_Of /= "" then
         J.Name (B, "body");
         J.Write_Raw (B, Body_Of);
      end if;
      J.End_Object (B);
      Emit (S, J.Result (B));
   end Respond;

   procedure Event
     (S : in out Session_State; Name : String; Body_Of : String := "");
   procedure Event
     (S : in out Session_State; Name : String; Body_Of : String := "")
   is
      B : J.Builder;
   begin
      J.Begin_Object (B);
      J.Name (B, "seq");
      J.Write_Integer (B, Next_Seq (S));
      J.Name (B, "type");
      J.Write_String (B, "event");
      J.Name (B, "event");
      J.Write_String (B, Name);
      if Body_Of /= "" then
         J.Name (B, "body");
         J.Write_Raw (B, Body_Of);
      end if;
      J.End_Object (B);
      Emit (S, J.Result (B));
   end Event;

   procedure Output
     (S : in out Session_State; Category, Text : String);
   procedure Output
     (S : in out Session_State; Category, Text : String)
   is
      B : J.Builder;
   begin
      J.Begin_Object (B);
      J.Name (B, "category");
      J.Write_String (B, Category);
      J.Name (B, "output");
      J.Write_String (B, Text);
      J.End_Object (B);
      Event (S, "output", J.Result (B));
   end Output;

   ---------------------------------------------------------------------
   --  Waiting
   ---------------------------------------------------------------------

   --  Wait up to Limit for the debugger, passing on whatever the program
   --  writes meanwhile.  Debugger says whether the debugger has bytes;
   --  Editor whether the editor has.
   procedure Wait_For
     (S : in out Session_State; Limit : Duration;
      Debugger, Editor : out Boolean);
   procedure Wait_For
     (S : in out Session_State; Limit : Duration;
      Debugger, Editor : out Boolean)
   is
      Ready : P.Ready_Streams;
   begin
      S.Debugger.Wait (S.Client.all, Limit, Ready);
      for Stream in P.Program_Output .. P.Program_Errors loop
         if Ready (Stream) then
            declare
               Chunk : String (1 .. 8192);
               Last : Natural;
            begin
               S.Debugger.Read (Stream, Chunk, Last);
               if Last >= Chunk'First then
                  Output (S, (if P."=" (Stream, P.Program_Output) then "stdout"
                              else "stderr"), Chunk (1 .. Last));
               end if;
            end;
         end if;
      end loop;
      Debugger := Ready (P.Debugger);
      Editor := Ready (P.Editor);
   end Wait_For;

   ---------------------------------------------------------------------
   --  GDB
   ---------------------------------------------------------------------

   --  Whole lines from the debugger: read once, and split what has come.
   --  Lines go to Into; the end of the debugger's output raises
   --  Debugger_Ended.
   procedure Read_Lines
     (S : in out Session_State; Into : out Text_Vectors.Vector);
   procedure Read_Lines
     (S : in out Session_State; Into : out Text_Vectors.Vector)
   is
      Chunk : String (1 .. 65_536);
      Last : Natural;
   begin
      Into.Clear;
      S.Debugger.Read (P.Debugger, Chunk, Last);
      if Last < Chunk'First then
         raise Debugger_Ended;
      end if;
      US.Append (S.Buffer, Chunk (1 .. Last));
      loop
         declare
            At_End : constant Natural := US.Index (S.Buffer, [ASCII.LF]);
         begin
            exit when At_End = 0;
            declare
               Line : constant String := US.Slice (S.Buffer, 1, At_End - 1);
            begin
               US.Delete (S.Buffer, 1, At_End);
               Into.Append
                 (if Line'Length > 0 and then Line (Line'Last) = ASCII.CR
                  then Line (Line'First .. Line'Last - 1) else Line);
            end;
         end;
      end loop;
   end Read_Lines;

   --  Pass a line that is not an answer on: a stream the program wrote
   --  to, or an asynchronous record kept for the main loop.
   procedure Keep (S : in out Session_State; Text : String);
   procedure Keep (S : in out Session_State; Text : String) is
      Line : constant Landin.Adapter.MI.Line := Landin.Adapter.MI.Parse (Text);
   begin
      case Line.Kind is
         when Landin.Adapter.MI.Target =>
            Output (S, "stdout", US.To_String (Line.Text));
         when Landin.Adapter.MI.Other =>
            if Text /= "" then
               Output (S, "stdout", Text & ASCII.LF);
            end if;
         when Landin.Adapter.MI.Exec | Landin.Adapter.MI.Notify
            | Landin.Adapter.MI.Status | Landin.Adapter.MI.Result =>
            S.Pending.Append (Text);
         when others =>
            null;
      end case;
   end Keep;

   --  Send one MI command and wait for its result record.  Class is its
   --  class, `done`, `running`, `connected` or `error`, and Results its
   --  results as JSON; Message an error's `msg`.
   procedure Command
     (S : in out Session_State; Text : String;
      Class : out US.Unbounded_String; Results : out US.Unbounded_String);
   procedure Command
     (S : in out Session_State; Text : String;
      Class : out US.Unbounded_String; Results : out US.Unbounded_String)
   is
      Token : Natural;
      Sent : Boolean;
      Deadline : constant Ada.Calendar.Time :=
        Ada.Calendar.Clock + Answer_Limit;
      Lines : Text_Vectors.Vector;
   begin
      S.Next_Token := S.Next_Token + 1;
      Token := S.Next_Token;
      S.Debugger.Send (Image (Token) & Text & ASCII.LF, Sent);
      if not Sent then
         raise Debugger_Ended;
      end if;
      loop
         declare
            Has_Bytes, Unused : Boolean;
            Left : constant Duration := Deadline - Ada.Calendar.Clock;
         begin
            if Left <= 0.0 then
               raise No_Answer with Text;
            end if;
            Wait_For (S, Left, Has_Bytes, Unused);
            if Has_Bytes then
               Read_Lines (S, Lines);
               for Index in 1 .. Natural (Lines.Length) loop
                  declare
                     Line : constant Landin.Adapter.MI.Line :=
                       Landin.Adapter.MI.Parse (Lines (Index));
                  begin
                     if Line.Kind = Landin.Adapter.MI.Result
                       and then Line.Token = Token
                     then
                        Class := Line.Class;
                        Results := Line.Results;
                        --  What came after the answer is kept in order.
                        for Later in Index + 1 .. Natural (Lines.Length) loop
                           Keep (S, Lines (Later));
                        end loop;
                        return;
                     end if;
                     Keep (S, Lines (Index));
                  end;
               end loop;
            end if;
         end;
      end loop;
   end Command;

   --  The `msg` of an error's results.
   function Message_Of (Results : US.Unbounded_String) return String;
   function Message_Of (Results : US.Unbounded_String) return String is
      D : J.Document;
   begin
      J.Parse (D, US.To_String (Results));
      if not J.Ok (D) then
         return "";
      end if;
      return Text_Of (D, J.Root (D), "msg");
   end Message_Of;

   --  Send Text and require `done` (or Wanted).  Failure is "" or why not.
   procedure Require
     (S : in out Session_State; Text : String;
      Failure : in out US.Unbounded_String;
      Wanted : String := "done");
   procedure Require
     (S : in out Session_State; Text : String;
      Failure : in out US.Unbounded_String;
      Wanted : String := "done")
   is
      Class, Results : US.Unbounded_String;
   begin
      if Failure /= US.Null_Unbounded_String then
         return;
      end if;
      Command (S, Text, Class, Results);
      if US.To_String (Class) /= Wanted then
         Failure := US.To_Unbounded_String
           (if Message_Of (Results) /= "" then Message_Of (Results)
            else "GDB answered " & US.To_String (Class) & " to " & Text);
      end if;
   end Require;

   function Console (Text : String) return String is
     ("-interpreter-exec console " & Landin.Adapter.MI.Quoted (Text));

   --  Forget every variables reference; GDB's variable objects are deleted.
   procedure Forget_References (S : in out Session_State);
   procedure Forget_References (S : in out Session_State) is
      Class, Results : US.Unbounded_String;
   begin
      S.References.Clear;
      S.Panic := US.Null_Unbounded_String;
      S.Panic_Kind := US.Null_Unbounded_String;
      if S.Kind = GDB and then S.Started then
         for Name of S.Objects loop
            Command (S, "-var-delete " & Name, Class, Results);
         end loop;
      end if;
      S.Objects.Clear;
   end Forget_References;

   function New_Reference (S : in out Session_State; Item : Reference)
     return Long_Long_Integer;
   function New_Reference (S : in out Session_State; Item : Reference)
     return Long_Long_Integer is
   begin
      S.References.Append (Item);
      return Long_Long_Integer (S.References.Length);
   end New_Reference;

   function Quoted_Argument (Item : String) return String;
   --  Item as a POSIX shell reads it back, in single quotes.
   function Quoted_Argument (Item : String) return String is
      Written : US.Unbounded_String := US.To_Unbounded_String ("'");
   begin
      for C of Item loop
         if C = ''' then
            US.Append (Written, "'\''");
         else
            US.Append (Written, C);
         end if;
      end loop;
      US.Append (Written, "'");
      return US.To_String (Written);
   end Quoted_Argument;

   ---------------------------------------------------------------------
   --  Panics (D1526)
   ---------------------------------------------------------------------

   --  The stop is in a `panic_handler` that received Site: describe it.
   procedure Describe_Panic (S : in out Session_State; Site : String;
                             Files : P.Filesystem'Class);
   procedure Describe_Panic (S : in out Session_State; Site : String;
                             Files : P.Filesystem'Class)
   is
      Value : constant Long_Long_Integer :=
        Number (Ada.Strings.Fixed.Trim (Site, Ada.Strings.Both));
   begin
      if Value < 0 or else Value > 2 ** 32 - 1 then
         S.Panic := US.To_Unbounded_String
           ("panic_handler was called; its site, " & Site
            & ", is not a number refine-dap can read");
         S.Panic_Kind := US.To_Unbounded_String ("panic");
         return;
      end if;
      declare
         Found : constant Landin.Site_Tables.Answer :=
           Landin.Site_Tables.Resolve_Site
             (US.To_String (S.Program), "",
              Interfaces.Unsigned_32 (Value), Files);
      begin
         if Found.Kind = Landin.Site_Tables.Resolved then
            S.Panic := US.To_Unbounded_String
              ("panic: " & US.To_String (Found.Reason) & " at "
               & Local_Path (US.To_String (Found.Path),
                             US.To_String (S.Library))
               & ":" & Image (Found.Line) & ":" & Image (Found.Column));
            S.Panic_Kind := Found.Reason;
         else
            S.Panic := US.To_Unbounded_String
              ("panic at site " & Image (Value) & ", which "
               & US.To_String (S.Program) & ".sources.json does not"
               & " resolve: " & US.To_String (Found.Message));
            S.Panic_Kind := US.To_Unbounded_String ("panic");
         end if;
      end;
   end Describe_Panic;

   function Exception_Body (S : Session_State) return String;
   function Exception_Body (S : Session_State) return String is
      B : J.Builder;
   begin
      J.Begin_Object (B);
      J.Name (B, "exceptionId");
      J.Write_String (B, US.To_String (S.Panic_Kind));
      J.Name (B, "description");
      J.Write_String (B, US.To_String (S.Panic));
      J.Name (B, "breakMode");
      J.Write_String (B, "always");
      J.End_Object (B);
      return J.Result (B);
   end Exception_Body;

   ---------------------------------------------------------------------
   --  GDB's asynchronous records
   ---------------------------------------------------------------------

   Signal_Numbers : constant array (1 .. 8) of access constant String :=
     [new String'("SIGHUP"), new String'("SIGINT"), new String'("SIGQUIT"),
      new String'("SIGILL"), new String'("SIGTRAP"), new String'("SIGABRT"),
      new String'("SIGBUS"), new String'("SIGFPE")];

   function Signal_Status (Name : String) return Integer;
   function Signal_Status (Name : String) return Integer is
   begin
      for Index in Signal_Numbers'Range loop
         if Signal_Numbers (Index).all = Name then
            --  SIGBUS is 7 on Linux, the only host GDB serves here.
            return 128 + Index;
         end if;
      end loop;
      return (if Name = "SIGKILL" then 137 elsif Name = "SIGSEGV" then 139
              elsif Name = "SIGTERM" then 143 else 1);
   end Signal_Status;

   procedure Stopped_By_GDB
     (S : in out Session_State; Results : String;
      Files : P.Filesystem'Class);
   procedure Stopped_By_GDB
     (S : in out Session_State; Results : String;
      Files : P.Filesystem'Class)
   is
      D : J.Document;
   begin
      J.Parse (D, Results);
      if not J.Ok (D) then
         return;
      end if;
      declare
         Root : constant J.Value := J.Root (D);
         Reason : constant String := Text_Of (D, Root, "reason");
         Thread : constant Long_Long_Integer :=
           Number_Of (D, Root, "thread-id");
         Frame : constant J.Value := J.Member (D, Root, "frame");
         B : J.Builder;
         Why : US.Unbounded_String;
         Description : US.Unbounded_String;
      begin
         if Reason in "exited-normally" | "exited" | "exited-signalled" then
            declare
               Code : constant Long_Long_Integer :=
                 (if Reason = "exited-normally" then 0
                  elsif Reason = "exited"
                  then Octal (Text_Of (D, Root, "exit-code"))
                  else Long_Long_Integer
                    (Signal_Status (Text_Of (D, Root, "signal-name"))));
            begin
               J.Begin_Object (B);
               J.Name (B, "exitCode");
               J.Write_Integer (B, Code);
               J.End_Object (B);
               Event (S, "exited", J.Result (B));
               Event (S, "terminated");
            end;
            return;
         end if;
         Forget_References (S);
         if Reason = "breakpoint-hit" then
            Why := US.To_Unbounded_String ("breakpoint");
         elsif Reason in "end-stepping-range" | "function-finished"
           | "location-reached"
         then
            Why := US.To_Unbounded_String ("step");
         elsif Reason = "signal-received"
           and then Text_Of (D, Root, "signal-name") = "SIGINT"
           and then S.Pause_Asked
         then
            Why := US.To_Unbounded_String ("pause");
         elsif Reason = "signal-received" then
            Why := US.To_Unbounded_String ("exception");
            Description := US.To_Unbounded_String
              (Text_Of (D, Root, "signal-name") & ", "
               & Text_Of (D, Root, "signal-meaning"));
            S.Panic := Description;
            S.Panic_Kind := US.To_Unbounded_String
              (Text_Of (D, Root, "signal-name"));
         else
            Why := US.To_Unbounded_String
              (if S.Pause_Asked then "pause" else "entry");
         end if;
         S.Pause_Asked := False;
         if Text_Of (D, Frame, "func") = "panic_handler" then
            declare
               Class, Answer : US.Unbounded_String;
            begin
               Command (S, "-data-evaluate-expression --thread "
                        & Image (Thread) & " --frame 0 site", Class, Answer);
               if US.To_String (Class) = "done" then
                  declare
                     A : J.Document;
                  begin
                     J.Parse (A, US.To_String (Answer));
                     if J.Ok (A) then
                        Describe_Panic
                          (S, Text_Of (A, J.Root (A), "value"), Files);
                        Why := US.To_Unbounded_String ("exception");
                        Description := S.Panic;
                     end if;
                  end;
               end if;
            end;
         end if;
         J.Begin_Object (B);
         J.Name (B, "reason");
         J.Write_String (B, US.To_String (Why));
         if Description /= US.Null_Unbounded_String then
            J.Name (B, "description");
            J.Write_String (B, US.To_String (Description));
            J.Name (B, "text");
            J.Write_String (B, US.To_String (Description));
         end if;
         J.Name (B, "threadId");
         J.Write_Integer (B, (if Thread > 0 then Thread else 1));
         J.Name (B, "allThreadsStopped");
         J.Write_Boolean (B, True);
         if Reason = "breakpoint-hit" then
            J.Name (B, "hitBreakpointIds");
            J.Begin_Array (B);
            J.Write_Integer (B, Number_Of (D, Root, "bkptno"));
            J.End_Array (B);
         end if;
         J.End_Object (B);
         Event (S, "stopped", J.Result (B));
      end;
   end Stopped_By_GDB;

   --  The records that arrived while nothing waited for them.
   procedure Drain_GDB (S : in out Session_State; Files : P.Filesystem'Class);
   procedure Drain_GDB (S : in out Session_State; Files : P.Filesystem'Class)
   is
   begin
      while not S.Pending.Is_Empty loop
         declare
            Text : constant String := S.Pending.First_Element;
            Line : constant Landin.Adapter.MI.Line :=
              Landin.Adapter.MI.Parse (Text);
         begin
            S.Pending.Delete_First;
            if Line.Kind = Landin.Adapter.MI.Exec
              and then US.To_String (Line.Class) = "stopped"
              and then S.Configured
            then
               Stopped_By_GDB (S, US.To_String (Line.Results), Files);
            end if;
         end;
      end loop;
   end Drain_GDB;

   ---------------------------------------------------------------------
   --  GDB's answers to the editor's requests
   ---------------------------------------------------------------------

   function Thread_Option (Thread : Long_Long_Integer) return String is
     (if Thread > 0 then " --thread " & Image (Thread) else "");

   procedure Answer_GDB
     (S : in out Session_State; D : J.Document; Seq : Long_Long_Integer;
      Name : String; Files : P.Filesystem'Class);
   procedure Answer_GDB
     (S : in out Session_State; D : J.Document; Seq : Long_Long_Integer;
      Name : String; Files : P.Filesystem'Class)
   is
      Arguments : constant J.Value := J.Member (D, J.Root (D), "arguments");
      Class, Results : US.Unbounded_String;

      procedure Fail (Message : String);
      procedure Fail (Message : String) is
      begin
         Respond (S, Seq, Name, False, Message);
      end Fail;

      procedure Resume (MI_Command : String; Thread : Long_Long_Integer);
      procedure Resume (MI_Command : String; Thread : Long_Long_Integer) is
      begin
         Forget_References (S);
         Command (S, MI_Command & Thread_Option (Thread), Class, Results);
         if US.To_String (Class) = "running" then
            Respond (S, Seq, Name, True,
                     Body_Of => (if Name = "continue"
                                 then "{""allThreadsContinued"":true}"
                                 else ""));
         else
            Fail (Message_Of (Results));
         end if;
      end Resume;

      --  Insert one breakpoint at Location and describe it for the editor.
      procedure Insert
        (B : in out J.Builder; Location, Condition : String;
         Line : Long_Long_Integer; Numbers : in out US.Unbounded_String);
      procedure Insert
        (B : in out J.Builder; Location, Condition : String;
         Line : Long_Long_Integer; Numbers : in out US.Unbounded_String) is
      begin
         Command (S, "-break-insert -f"
                  & (if Condition = "" then ""
                     else " -c " & Landin.Adapter.MI.Quoted (Condition))
                  & " " & Landin.Adapter.MI.Quoted (Location),
                  Class, Results);
         J.Begin_Object (B);
         if US.To_String (Class) = "done" then
            declare
               R : J.Document;
            begin
               J.Parse (R, US.To_String (Results));
               declare
                  Point : constant J.Value :=
                    J.Member (R, J.Root (R), "bkpt");
                  Point_Number : constant String :=
                    Text_Of (R, Point, "number");
               begin
                  US.Append (Numbers, " " & Point_Number);
                  J.Name (B, "id");
                  J.Write_Integer (B, Number (Point_Number));
                  J.Name (B, "verified");
                  J.Write_Boolean
                    (B, Text_Of (R, Point, "addr") /= "<PENDING>"
                        and then Text_Of (R, Point, "addr") /= "");
                  if Number_Of (R, Point, "line") > 0 then
                     J.Name (B, "line");
                     J.Write_Integer (B, Number_Of (R, Point, "line"));
                  elsif Line > 0 then
                     J.Name (B, "line");
                     J.Write_Integer (B, Line);
                  end if;
               end;
            end;
         else
            J.Name (B, "verified");
            J.Write_Boolean (B, False);
            J.Name (B, "message");
            J.Write_String (B, Message_Of (Results));
         end if;
         J.End_Object (B);
      end Insert;

      --  Delete the breakpoints Key set before.
      procedure Clear (Key : String);
      procedure Clear (Key : String) is
      begin
         if S.Breakpoints.Contains (Key) then
            if S.Breakpoints (Key) /= "" then
               Command (S, "-break-delete" & S.Breakpoints (Key), Class,
                        Results);
            end if;
            S.Breakpoints.Delete (Key);
         end if;
      end Clear;

      Library : constant String := US.To_String (S.Library);
   begin
      if Name = "setBreakpoints" then
         declare
            Source : constant J.Value := J.Member (D, Arguments, "source");
            Path : constant String := Text_Of (D, Source, "path");
            Points : constant J.Value :=
              J.Member (D, Arguments, "breakpoints");
            B : J.Builder;
            Numbers : US.Unbounded_String;
         begin
            if Path = "" then
               Fail ("refine-dap sets breakpoints in a source named by its"
                     & " path");
               return;
            end if;
            Clear ("source:" & Path);
            J.Begin_Object (B);
            J.Name (B, "breakpoints");
            J.Begin_Array (B);
            if J.Is_Kind (D, Points, J.Array_Value) then
               for Index in 1 .. J.Length (D, Points) loop
                  declare
                     Point : constant J.Value := J.Element (D, Points, Index);
                     Line : constant Long_Long_Integer :=
                       Number_Of (D, Point, "line");
                  begin
                     Insert (B, Recorded_Path (Path, Library) & ":"
                             & Image (Line),
                             Text_Of (D, Point, "condition"), Line, Numbers);
                  end;
               end loop;
            end if;
            J.End_Array (B);
            J.End_Object (B);
            S.Breakpoints.Include ("source:" & Path, US.To_String (Numbers));
            Respond (S, Seq, Name, True, Body_Of => J.Result (B));
         end;
      elsif Name = "setFunctionBreakpoints" then
         declare
            Points : constant J.Value :=
              J.Member (D, Arguments, "breakpoints");
            B : J.Builder;
            Numbers : US.Unbounded_String;
         begin
            Clear ("functions");
            J.Begin_Object (B);
            J.Name (B, "breakpoints");
            J.Begin_Array (B);
            if J.Is_Kind (D, Points, J.Array_Value) then
               for Index in 1 .. J.Length (D, Points) loop
                  declare
                     Point : constant J.Value := J.Element (D, Points, Index);
                  begin
                     Insert (B, Text_Of (D, Point, "name"),
                             Text_Of (D, Point, "condition"), 0, Numbers);
                  end;
               end loop;
            end if;
            J.End_Array (B);
            J.End_Object (B);
            S.Breakpoints.Include ("functions", US.To_String (Numbers));
            Respond (S, Seq, Name, True, Body_Of => J.Result (B));
         end;
      elsif Name = "setExceptionBreakpoints" then
         Respond (S, Seq, Name, True, Body_Of => "{""breakpoints"":[]}");
      elsif Name = "configurationDone" then
         S.Configured := True;
         Command (S, (if S.Attached then "-exec-continue"
                      elsif S.Stop_On_Entry then "-exec-run --start"
                      else "-exec-run"), Class, Results);
         if US.To_String (Class) = "running" then
            Respond (S, Seq, Name, True);
         else
            Fail (Message_Of (Results));
         end if;
      elsif Name = "threads" then
         Command (S, "-thread-info", Class, Results);
         declare
            R : J.Document;
            B : J.Builder;
         begin
            J.Parse (R, US.To_String (Results));
            J.Begin_Object (B);
            J.Name (B, "threads");
            J.Begin_Array (B);
            if US.To_String (Class) = "done" and then J.Ok (R) then
               declare
                  List : constant J.Value :=
                    J.Member (R, J.Root (R), "threads");
               begin
                  if J.Is_Kind (R, List, J.Array_Value) then
                     for Index in 1 .. J.Length (R, List) loop
                        declare
                           T : constant J.Value := J.Element (R, List, Index);
                        begin
                           J.Begin_Object (B);
                           J.Name (B, "id");
                           J.Write_Integer (B, Number_Of (R, T, "id"));
                           J.Name (B, "name");
                           J.Write_String
                             (B, (if Text_Of (R, T, "name") /= ""
                                  then Text_Of (R, T, "name")
                                  else Text_Of (R, T, "target-id")));
                           J.End_Object (B);
                        end;
                     end loop;
                  end if;
               end;
            end if;
            J.End_Array (B);
            J.End_Object (B);
            Respond (S, Seq, Name, True, Body_Of => J.Result (B));
         end;
      elsif Name = "stackTrace" then
         declare
            Thread : constant Long_Long_Integer :=
              Number_Of (D, Arguments, "threadId");
            First : constant Long_Long_Integer :=
              Long_Long_Integer'Max
                (0, Number_Of (D, Arguments, "startFrame"));
            Levels : constant Long_Long_Integer :=
              Number_Of (D, Arguments, "levels");
            R : J.Document;
            B : J.Builder;
         begin
            Command (S, "-stack-list-frames" & Thread_Option (Thread)
                     & (if Levels > 0
                        then " " & Image (First) & " "
                          & Image (First + Levels - 1)
                        elsif First > 0 then " " & Image (First) & " 100000"
                        else ""), Class, Results);
            if US.To_String (Class) /= "done" then
               Fail (Message_Of (Results));
               return;
            end if;
            J.Parse (R, US.To_String (Results));
            J.Begin_Object (B);
            J.Name (B, "stackFrames");
            J.Begin_Array (B);
            declare
               List : constant J.Value := J.Member (R, J.Root (R), "stack");
            begin
               if J.Is_Kind (R, List, J.Array_Value) then
                  for Index in 1 .. J.Length (R, List) loop
                     declare
                        F : constant J.Value := J.Element (R, List, Index);
                        Level : constant Long_Long_Integer :=
                          Number_Of (R, F, "level");
                        Where : constant String :=
                          (if Text_Of (R, F, "fullname") /= ""
                           then Text_Of (R, F, "fullname")
                           else Text_Of (R, F, "file"));
                        Shown : constant String := Local_Path (Where, Library);
                        Slash : constant Natural := Ada.Strings.Fixed.Index
                          (Shown, "/", Ada.Strings.Backward);
                     begin
                        J.Begin_Object (B);
                        J.Name (B, "id");
                        J.Write_Integer
                          (B, Long_Long_Integer'Max (Thread, 1) * Frame_Stride
                              + Level);
                        J.Name (B, "name");
                        J.Write_String
                          (B, (if Text_Of (R, F, "func") /= ""
                               then Text_Of (R, F, "func")
                               else Text_Of (R, F, "addr")));
                        if Where /= "" then
                           J.Name (B, "source");
                           J.Begin_Object (B);
                           J.Name (B, "name");
                           J.Write_String (B, Shown (Slash + 1 .. Shown'Last));
                           J.Name (B, "path");
                           J.Write_String (B, Shown);
                           J.End_Object (B);
                        end if;
                        J.Name (B, "line");
                        J.Write_Integer
                          (B, Long_Long_Integer'Max
                             (0, Number_Of (R, F, "line")));
                        J.Name (B, "column");
                        J.Write_Integer (B, (if Where /= "" then 1 else 0));
                        if Text_Of (R, F, "addr") /= "" then
                           J.Name (B, "instructionPointerReference");
                           J.Write_String (B, Text_Of (R, F, "addr"));
                        end if;
                        J.End_Object (B);
                     end;
                  end loop;
               end if;
            end;
            J.End_Array (B);
            J.End_Object (B);
            Respond (S, Seq, Name, True, Body_Of => J.Result (B));
         end;
      elsif Name = "scopes" then
         declare
            Frame : constant Long_Long_Integer :=
              Number_Of (D, Arguments, "frameId");
            Ref : constant Long_Long_Integer := New_Reference
              (S, (Kind => Frame_Locals,
                   Thread => Natural (Frame / Frame_Stride),
                   Level => Natural (Frame mod Frame_Stride),
                   Name => US.Null_Unbounded_String));
         begin
            if Frame < Frame_Stride then
               Fail ("frame " & Image (Frame) & " is not one refine-dap"
                     & " named");
               return;
            end if;
            Respond (S, Seq, Name, True,
                     Body_Of => "{""scopes"":[{""name"":""Locals"","
                     & """presentationHint"":""locals"","
                     & """variablesReference"":" & Image (Ref)
                     & ",""expensive"":false}]}");
         end;
      elsif Name = "variables" then
         declare
            Ref : constant Long_Long_Integer :=
              Number_Of (D, Arguments, "variablesReference");
            Item : Reference;
            B : J.Builder;
            R : J.Document;

            procedure Variable
              (Shown, Value, Of_Type : String; Child : Long_Long_Integer);
            procedure Variable
              (Shown, Value, Of_Type : String; Child : Long_Long_Integer) is
            begin
               J.Begin_Object (B);
               J.Name (B, "name");
               J.Write_String (B, Shown);
               J.Name (B, "value");
               J.Write_String (B, Value);
               if Of_Type /= "" then
                  J.Name (B, "type");
                  J.Write_String (B, Of_Type);
               end if;
               J.Name (B, "variablesReference");
               J.Write_Integer (B, Child);
               J.End_Object (B);
            end Variable;

            --  The children of the variable object Object.
            procedure Children (Object : String);
            procedure Children (Object : String) is
               C : J.Document;
            begin
               Command (S, "-var-list-children --all-values " & Object,
                        Class, Results);
               J.Parse (C, US.To_String (Results));
               if US.To_String (Class) /= "done" or else not J.Ok (C) then
                  return;
               end if;
               declare
                  List : constant J.Value :=
                    J.Member (C, J.Root (C), "children");
               begin
                  if J.Is_Kind (C, List, J.Array_Value) then
                     for Index in 1 .. J.Length (C, List) loop
                        declare
                           E : constant J.Value := J.Element (C, List, Index);
                        begin
                           Variable
                             (Text_Of (C, E, "exp"), Text_Of (C, E, "value"),
                              Text_Of (C, E, "type"),
                              (if Number_Of (C, E, "numchild") > 0
                               then New_Reference
                                 (S, (Kind => Variable_Object, Thread => 0,
                                      Level => 0,
                                      Name => US.To_Unbounded_String
                                        (Text_Of (C, E, "name"))))
                               else 0));
                        end;
                     end loop;
                  end if;
               end;
            end Children;
         begin
            if Ref < 1 or else Ref > Long_Long_Integer (S.References.Length)
            then
               Fail ("variables reference " & Image (Ref) & " is not one"
                     & " refine-dap gave since the program last stopped");
               return;
            end if;
            Item := S.References (Positive (Ref));
            J.Begin_Object (B);
            J.Name (B, "variables");
            J.Begin_Array (B);
            case Item.Kind is
               when Frame_Locals =>
                  Command (S, "-stack-list-variables --thread "
                           & Image (Item.Thread) & " --frame "
                           & Image (Item.Level) & " --simple-values",
                           Class, Results);
                  J.Parse (R, US.To_String (Results));
                  if US.To_String (Class) = "done" and then J.Ok (R) then
                     declare
                        List : constant J.Value :=
                          J.Member (R, J.Root (R), "variables");
                     begin
                        if J.Is_Kind (R, List, J.Array_Value) then
                           for Index in 1 .. J.Length (R, List) loop
                              declare
                                 V : constant J.Value :=
                                   J.Element (R, List, Index);
                                 Simple : constant Boolean := J.Is_Present
                                   (J.Member (R, V, "value"));
                              begin
                                 Variable
                                   (Text_Of (R, V, "name"),
                                    (if Simple then Text_Of (R, V, "value")
                                     else Text_Of (R, V, "type")),
                                    Text_Of (R, V, "type"),
                                    (if Simple then 0
                                     else New_Reference
                                       (S, (Kind => Expression,
                                            Thread => Item.Thread,
                                            Level => Item.Level,
                                            Name => US.To_Unbounded_String
                                              (Text_Of (R, V, "name"))))));
                              end;
                           end loop;
                        end if;
                     end;
                  end if;
               when Expression =>
                  Command (S, "-var-create --thread " & Image (Item.Thread)
                           & " --frame " & Image (Item.Level) & " - * "
                           & Landin.Adapter.MI.Quoted
                             (US.To_String (Item.Name)), Class, Results);
                  J.Parse (R, US.To_String (Results));
                  if US.To_String (Class) = "done" and then J.Ok (R) then
                     declare
                        Object : constant String :=
                          Text_Of (R, J.Root (R), "name");
                     begin
                        S.Objects.Append (Object);
                        S.References.Replace_Element
                          (Positive (Ref),
                           (Kind => Variable_Object, Thread => 0, Level => 0,
                            Name => US.To_Unbounded_String (Object)));
                        Children (Object);
                     end;
                  end if;
               when Variable_Object =>
                  Children (US.To_String (Item.Name));
            end case;
            J.End_Array (B);
            J.End_Object (B);
            Respond (S, Seq, Name, True, Body_Of => J.Result (B));
         end;
      elsif Name = "evaluate" then
         declare
            Frame : constant Long_Long_Integer :=
              Number_Of (D, Arguments, "frameId");
            R : J.Document;
         begin
            Command (S, "-data-evaluate-expression"
                     & (if Frame >= Frame_Stride
                        then " --thread " & Image (Frame / Frame_Stride)
                          & " --frame " & Image (Frame mod Frame_Stride)
                        else "")
                     & " " & Landin.Adapter.MI.Quoted
                       (Text_Of (D, Arguments, "expression")),
                     Class, Results);
            J.Parse (R, US.To_String (Results));
            if US.To_String (Class) = "done" and then J.Ok (R) then
               declare
                  B : J.Builder;
               begin
                  J.Begin_Object (B);
                  J.Name (B, "result");
                  J.Write_String (B, Text_Of (R, J.Root (R), "value"));
                  J.Name (B, "variablesReference");
                  J.Write_Integer (B, 0);
                  J.End_Object (B);
                  Respond (S, Seq, Name, True, Body_Of => J.Result (B));
               end;
            else
               Fail (Message_Of (Results));
            end if;
         end;
      elsif Name = "exceptionInfo" then
         if S.Panic = US.Null_Unbounded_String then
            Fail ("the program did not stop for a panic or a signal");
         else
            Respond (S, Seq, Name, True, Body_Of => Exception_Body (S));
         end if;
      elsif Name = "continue" then
         Resume ("-exec-continue", 0);
      elsif Name = "next" then
         Resume ("-exec-next", Number_Of (D, Arguments, "threadId"));
      elsif Name = "stepIn" then
         Resume ("-exec-step", Number_Of (D, Arguments, "threadId"));
      elsif Name = "stepOut" then
         Resume ("-exec-finish --frame 0",
                 Number_Of (D, Arguments, "threadId"));
      elsif Name = "pause" then
         S.Pause_Asked := True;
         Command (S, "-exec-interrupt --all", Class, Results);
         if US.To_String (Class) = "done" then
            Respond (S, Seq, Name, True);
         else
            Fail (Message_Of (Results));
         end if;
      elsif Name = "terminate" then
         Command (S, Console ("kill"), Class, Results);
         Respond (S, Seq, Name, True);
         Event (S, "terminated");
      else
         Fail ("refine-dap does not answer """ & Name & """ over GDB");
      end if;
      pragma Unreferenced (Files);
   end Answer_GDB;

   ---------------------------------------------------------------------
   --  LLDB's own adapter, relayed
   ---------------------------------------------------------------------

   --  Send lldb-dap a request of our own and return its sequence number.
   function Ask_LLDB
     (S : in out Session_State; Command, Arguments : String;
      Client_Seq : Long_Long_Integer := 0; Ours : Boolean := True)
      return Long_Long_Integer;
   function Ask_LLDB
     (S : in out Session_State; Command, Arguments : String;
      Client_Seq : Long_Long_Integer := 0; Ours : Boolean := True)
      return Long_Long_Integer
   is
      B : J.Builder;
      Sent : Boolean;
   begin
      S.Relay_Seq := S.Relay_Seq + 1;
      J.Begin_Object (B);
      J.Name (B, "seq");
      J.Write_Integer (B, S.Relay_Seq);
      J.Name (B, "type");
      J.Write_String (B, "request");
      J.Name (B, "command");
      J.Write_String (B, Command);
      J.Name (B, "arguments");
      J.Write_Raw (B, Arguments);
      J.End_Object (B);
      S.In_Flight.Include
        (Image (S.Relay_Seq),
         (Client_Seq => Client_Seq,
          Command => US.To_Unbounded_String (Command), Ours => Ours));
      S.Debugger.Send (Transport.Framed (J.Result (B)), Sent);
      if not Sent then
         raise Debugger_Ended;
      end if;
      return S.Relay_Seq;
   end Ask_LLDB;

   --  The next message from lldb-dap, waiting up to Answer_Limit.
   function Next_From_LLDB (S : in out Session_State) return String;
   function Next_From_LLDB (S : in out Session_State) return String is
      Channel : Debugger_Channel (S'Unchecked_Access);
      Outcome : Transport.Status;
      Body_Of, Fault : US.Unbounded_String;
      Has_Bytes, Unused : Boolean;
   begin
      if not Transport.Waiting (S.Relay_Reader, Channel) then
         Wait_For (S, Answer_Limit, Has_Bytes, Unused);
         if not Has_Bytes then
            raise No_Answer with "lldb-dap";
         end if;
      end if;
      Transport.Next (S.Relay_Reader, Channel, Outcome, Body_Of, Fault);
      if Outcome /= Transport.Message then
         raise Debugger_Ended;
      end if;
      return US.To_String (Body_Of);
   end Next_From_LLDB;

   --  Wait for lldb-dap's answer to our own request Seq; everything else
   --  that arrives meanwhile is queued for the editor.
   procedure Await_LLDB
     (S : in out Session_State; Seq : Long_Long_Integer;
      Answer : out US.Unbounded_String);
   procedure Await_LLDB
     (S : in out Session_State; Seq : Long_Long_Integer;
      Answer : out US.Unbounded_String) is
   begin
      loop
         declare
            Text : constant String := Next_From_LLDB (S);
            D : J.Document;
         begin
            J.Parse (D, Text);
            if J.Ok (D)
              and then Text_Of (D, J.Root (D), "type") = "response"
              and then Number_Of (D, J.Root (D), "request_seq") = Seq
            then
               S.In_Flight.Exclude (Image (Seq));
               Answer := US.To_Unbounded_String (Text);
               return;
            end if;
            S.Relay_Queue.Append (Text);
         end;
      end loop;
   end Await_LLDB;

   --  A message of lldb-dap's, renumbered and sent to the editor.
   procedure Relay_To_Client
     (S : in out Session_State; Text : String; Files : P.Filesystem'Class);
   procedure Relay_To_Client
     (S : in out Session_State; Text : String; Files : P.Filesystem'Class)
   is
      D : J.Document;
      Request_Seq : Long_Long_Integer := 0;
      Finished_Now : Boolean := False;
   begin
      J.Parse (D, Text);
      if not J.Ok (D)
        or else not J.Is_Kind (D, J.Root (D), J.Object_Value)
      then
         return;
      end if;
      declare
         Root : constant J.Value := J.Root (D);
         Kind : constant String := Text_Of (D, Root, "type");
         B : J.Builder;
         Description : US.Unbounded_String;
      begin
         if Kind = "response" then
            declare
               Key : constant String :=
                 Image (Number_Of (D, Root, "request_seq"));
            begin
               if not S.In_Flight.Contains (Key)
                 or else S.In_Flight (Key).Ours
               then
                  S.In_Flight.Exclude (Key);
                  return;
               end if;
               Request_Seq := S.In_Flight (Key).Client_Seq;
               Finished_Now :=
                 US.To_String (S.In_Flight (Key).Command) = "disconnect";
               S.In_Flight.Exclude (Key);
            end;
         elsif Kind = "event"
           and then Text_Of (D, Root, "event") = "stopped"
         then
            Forget_References (S);
            declare
               Stop : constant J.Value := J.Member (D, Root, "body");
               Thread : constant Long_Long_Integer :=
                 Number_Of (D, Stop, "threadId");
               Answer : US.Unbounded_String;
               T : J.Document;
            begin
               --  Is it a panic_handler's stop (D1526)?
               Await_LLDB
                 (S, Ask_LLDB (S, "stackTrace", "{""threadId"":"
                               & Image (Thread) & ",""levels"":1}"),
                  Answer);
               J.Parse (T, US.To_String (Answer));
               if J.Ok (T) then
                  declare
                     Frames : constant J.Value := J.Member
                       (T, J.Member (T, J.Root (T), "body"), "stackFrames");
                  begin
                     if J.Is_Kind (T, Frames, J.Array_Value)
                       and then J.Length (T, Frames) > 0
                       and then Text_Of (T, J.Element (T, Frames, 1), "name")
                         = "panic_handler"
                     then
                        declare
                           Value : US.Unbounded_String;
                           E : J.Document;
                        begin
                           Await_LLDB
                             (S, Ask_LLDB
                                (S, "evaluate", "{""expression"":""site"","
                                 & """context"":""watch"",""frameId"":"
                                 & Image (Number_Of
                                   (T, J.Element (T, Frames, 1), "id"))
                                 & "}"), Value);
                           J.Parse (E, US.To_String (Value));
                           if J.Ok (E) and then Flag_Of
                             (E, J.Root (E), "success")
                           then
                              Describe_Panic
                                (S, Text_Of (E, J.Member
                                   (E, J.Root (E), "body"), "result"),
                                 Files);
                              Description := S.Panic;
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end;
         end if;
         J.Begin_Object (B);
         for Index in 1 .. J.Length (D, Root) loop
            declare
               Key : constant String := J.Key (D, Root, Index);
               Item : constant J.Value := J.Member_Value (D, Root, Index);
            begin
               if Key = "seq" then
                  J.Name (B, "seq");
                  J.Write_Integer (B, Next_Seq (S));
               elsif Key = "request_seq" then
                  J.Name (B, "request_seq");
                  J.Write_Integer (B, Request_Seq);
               elsif Key = "body" and then Description /= ""
                 and then J.Is_Kind (D, Item, J.Object_Value)
               then
                  J.Name (B, "body");
                  J.Begin_Object (B);
                  for Inner in 1 .. J.Length (D, Item) loop
                     declare
                        Field : constant String := J.Key (D, Item, Inner);
                     begin
                        if Field not in "reason" | "description" | "text"
                        then
                           J.Name (B, Field);
                           J.Copy (B, D, J.Member_Value (D, Item, Inner));
                        end if;
                     end;
                  end loop;
                  J.Name (B, "reason");
                  J.Write_String (B, "exception");
                  J.Name (B, "description");
                  J.Write_String (B, US.To_String (Description));
                  J.Name (B, "text");
                  J.Write_String (B, US.To_String (Description));
                  J.End_Object (B);
               else
                  J.Name (B, Key);
                  J.Copy (B, D, Item);
               end if;
            end;
         end loop;
         J.End_Object (B);
         Emit (S, J.Result (B));
         if Finished_Now then
            S.Finished := True;
         end if;
      end;
   end Relay_To_Client;

   --  The editor's request Text, relayed to lldb-dap.
   procedure Relay_To_LLDB
     (S : in out Session_State; D : J.Document; Seq : Long_Long_Integer;
      Name : String);
   procedure Relay_To_LLDB
     (S : in out Session_State; D : J.Document; Seq : Long_Long_Integer;
      Name : String)
   is
      Arguments : constant J.Value := J.Member (D, J.Root (D), "arguments");
      B : J.Builder;
      Unused : Long_Long_Integer;
   begin
      if Name = "exceptionInfo" and then S.Panic /= "" then
         Respond (S, Seq, Name, True, Body_Of => Exception_Body (S));
         return;
      end if;
      if J.Is_Present (Arguments) then
         J.Copy (B, D, Arguments);
      else
         J.Write_Raw (B, "{}");
      end if;
      Unused := Ask_LLDB (S, Name, J.Result (B), Seq, Ours => False);
   end Relay_To_LLDB;

   ---------------------------------------------------------------------
   --  Starting a session
   ---------------------------------------------------------------------

   --  Where `xcrun --find lldb-dap` says Xcode's adapter is, or
   --  `lldb-dap` when it cannot say.
   function Xcode_Find (Tools : P.Tool_Runner'Class) return String;
   function Xcode_Find (Tools : P.Tool_Runner'Class) return String is
      Answer : P.Tool_Result;
      Words : P.Path_List := P.Arguments ("--find");
      use type P.Termination;
   begin
      P.Add (Words, "lldb-dap");
      Tools.Run ("xcrun", Words, Answer, P.Output_Only);
      declare
         Found : constant String := Ada.Strings.Fixed.Trim
           (US.To_String (Answer.Output),
            Ada.Strings.Maps.To_Set (" " & ASCII.LF & ASCII.CR),
            Ada.Strings.Maps.To_Set (" " & ASCII.LF & ASCII.CR));
      begin
         return (if Answer.Ended = P.Exited and then Answer.Exit_Code = 0
                   and then Found /= "" then Found else "lldb-dap");
      end;
   exception
      when others =>
         return "lldb-dap";
   end Xcode_Find;

   procedure Start_Session
     (S : in out Session_State; D : J.Document; Seq : Long_Long_Integer;
      Name : String; Files : P.Filesystem'Class;
      Tools : P.Tool_Runner'Class);
   procedure Start_Session
     (S : in out Session_State; D : J.Document; Seq : Long_Long_Integer;
      Name : String; Files : P.Filesystem'Class;
      Tools : P.Tool_Runner'Class)
   is
      Arguments : constant J.Value := J.Member (D, J.Root (D), "arguments");
      Given : constant String := Text_Of (D, Arguments, "program");
      Directory : constant String := Text_Of (D, Arguments, "cwd");
      Program : constant String :=
        (if Given = "" or else Given (Given'First) = '/' then Given
         elsif Directory /= "" then Directory & "/" & Given
         else Files.Working_Directory & "/" & Given);
      Named : constant String := Text_Of (D, Arguments, "debugger");
      Remote : constant String := Text_Of (D, Arguments, "remote");
      Content : US.Unbounded_String;
      Read : P.Read_Status;
      Failure : US.Unbounded_String;
      Library : constant String := US.To_String (S.Library);
      use type P.Read_Status;
   begin
      if S.Started then
         Respond (S, Seq, Name, False, "a program is already being"
                  & " debugged in this session");
         return;
      elsif Given = "" then
         Respond (S, Seq, Name, False, Name & " needs ""program"", the"
                  & " path of the executable refine compile wrote");
         return;
      elsif Name = "attach" and then Remote = "" then
         Respond (S, Seq, Name, False, "attach needs ""remote"", where a"
                  & " debugger stub listens: HOST:PORT, or for GDB a"
                  & " socket's path");
         return;
      elsif Named not in "" | "gdb" | "lldb" then
         Respond (S, Seq, Name, False, """debugger"" is ""gdb"" or"
                  & " ""lldb"", not """ & Named & """");
         return;
      end if;
      Files.Read_File (Program, Content, Read);
      if Read /= P.Read_Ok then
         Respond (S, Seq, Name, False, "cannot read the program "
                  & Program & (if Read = P.Not_Found
                               then ": it does not exist" else ""));
         return;
      end if;
      S.Program := US.To_Unbounded_String (Program);
      S.Attached := Name = "attach";
      S.Stop_On_Entry := Flag_Of (D, Arguments, "stopOnEntry");
      S.Kind :=
        (if Named = "gdb" then GDB elsif Named = "lldb" then LLDB
         else Debugger_For
           (US.Slice (Content, 1, Natural'Min (64, US.Length (Content)))));

      declare
         Path : constant String := Text_Of (D, Arguments, "debuggerPath");
         Words : P.Path_List;
         Settings : P.Path_List;
         Default : constant String :=
           (if S.Kind = GDB then "gdb" else "lldb-dap");
         Found : constant String :=
           (if Path /= "" then Path
            elsif Tools.Available (Default) then Default
            elsif S.Kind = LLDB and then Tools.Available ("xcrun")
            then
              --  Xcode's lldb-dap is not on the search path.
              Xcode_Find (Tools)
            else Default);
      begin
         P.Add (Words, Found);
         if S.Kind = GDB then
            P.Add (Words, "--interpreter=mi3");
            P.Add (Words, "-q");
            P.Add (Words, "-nx");
            if not S.Attached then
               --  GDB starts the program through $SHELL, whose
               --  redirections give it the pipes (D1524).
               P.Add (Settings, "SHELL=/bin/sh");
            end if;
         end if;
         S.Debugger.Start (Words, Settings,
                           S.Kind = GDB and then not S.Attached, Failure);
         if Failure /= "" then
            Respond (S, Seq, Name, False, "cannot start "
                     & (if S.Kind = GDB then "GDB" else "LLDB's adapter")
                     & " as " & Found & ": " & US.To_String (Failure)
                     & "; name the debugger with ""debuggerPath""");
            return;
         end if;
         S.Started := True;
      end;

      if S.Kind = GDB then
         Require (S, "-gdb-set confirm off", Failure);
         Require (S, "-gdb-set pagination off", Failure);
         Require (S, "-gdb-set width 0", Failure);
         if Library /= "" then
            for Space of Namespaces loop
               Require (S, Console ("set substitute-path " & Recorded_Prefix
                                    & Space.all & " " & Library & "/"
                                    & Space.all), Failure);
            end loop;
         end if;
         if Directory /= "" then
            Require (S, "-environment-cd "
                     & Landin.Adapter.MI.Quoted (Directory), Failure);
         end if;
         Require (S, "-file-exec-and-symbols "
                  & Landin.Adapter.MI.Quoted (Program), Failure);
         if S.Attached then
            Require (S, "-target-select remote "
                     & Landin.Adapter.MI.Quoted (Remote), Failure,
                     Wanted => "connected");
         else
            declare
               Shell : constant String := S.Debugger.Variable ("SHELL");
               Words : constant J.Value := J.Member (D, Arguments, "args");
               Line : US.Unbounded_String;
            begin
               Require (S, Console
                          (if Shell = "" then "unset environment SHELL"
                           else "set environment SHELL=" & Shell),
                        Failure);
               if J.Is_Kind (D, Words, J.Array_Value) then
                  for Index in 1 .. J.Length (D, Words) loop
                     US.Append (Line, Quoted_Argument
                                (Text_Of_Element (D, Words, Index)) & " ");
                  end loop;
               end if;
               Require (S, "-exec-arguments " & US.To_String (Line)
                        & "</dev/null >&3 2>&4", Failure);
            end;
         end if;
         --  Nothing the start-up said is the editor's yet.
         S.Pending.Clear;
         if Failure /= "" then
            Respond (S, Seq, Name, False, US.To_String (Failure));
            return;
         end if;
         Respond (S, Seq, Name, True);
         Event (S, "initialized");
      else
         declare
            Answer : US.Unbounded_String;
            B : J.Builder;
            Colon : constant Natural := Ada.Strings.Fixed.Index
              (Remote, ":", Ada.Strings.Backward);
            Unused : Long_Long_Integer;
         begin
            Await_LLDB (S, Ask_LLDB (S, "initialize",
                                     US.To_String (S.Initialize)), Answer);
            J.Begin_Object (B);
            for Index in 1 .. J.Length (D, Arguments) loop
               declare
                  Key : constant String := J.Key (D, Arguments, Index);
               begin
                  if Key not in "debugger" | "debuggerPath" | "remote"
                    | "sourceMap" | "program"
                  then
                     J.Name (B, Key);
                     J.Copy (B, D, J.Member_Value (D, Arguments, Index));
                  end if;
               end;
            end loop;
            J.Name (B, "program");
            J.Write_String (B, Program);
            if Library /= "" then
               J.Name (B, "sourceMap");
               J.Begin_Array (B);
               for Space of Namespaces loop
                  J.Begin_Array (B);
                  J.Write_String (B, Recorded_Prefix & Space.all);
                  J.Write_String (B, Library & "/" & Space.all);
                  J.End_Array (B);
               end loop;
               J.End_Array (B);
            end if;
            if S.Attached then
               J.Name (B, "gdb-remote-hostname");
               J.Write_String
                 (B, (if Colon > Remote'First
                      then Remote (Remote'First .. Colon - 1)
                      else "127.0.0.1"));
               J.Name (B, "gdb-remote-port");
               J.Write_Integer
                 (B, Number (Remote (Colon + 1 .. Remote'Last)));
            end if;
            J.End_Object (B);
            Unused := Ask_LLDB (S, Name, J.Result (B), Seq, Ours => False);
         end;
      end if;
   end Start_Session;

   ---------------------------------------------------------------------
   --  Serving
   ---------------------------------------------------------------------

   procedure Serve
     (Client   : in out Landin.Platform.Channel'Class;
      Debugger : aliased in out Landin.Platform.Debugger_Session'Class;
      Files    : Landin.Platform.Filesystem'Class;
      Tools    : Landin.Platform.Tool_Runner'Class;
      Library  : String;
      Status   : out Integer)
   is
      S : aliased Session_State (Client'Unchecked_Access, Debugger'Access);

      procedure Finish;
      procedure Finish is
         Ended : Integer;
      begin
         if S.Started then
            S.Debugger.Stop (Stop_Grace, Ended);
            S.Started := False;
         end if;
      end Finish;

      --  One request of the editor's.
      procedure Request (Text : String);
      procedure Request (Text : String) is
         D : J.Document;
      begin
         J.Parse (D, Text);
         if not J.Ok (D)
           or else Text_Of (D, J.Root (D), "type") /= "request"
         then
            return;
         end if;
         declare
            Seq : constant Long_Long_Integer :=
              Number_Of (D, J.Root (D), "seq");
            Name : constant String := Text_Of (D, J.Root (D), "command");
         begin
            if Name = "initialize" then
               declare
                  B : J.Builder;
               begin
                  if J.Is_Present (J.Member (D, J.Root (D), "arguments")) then
                     J.Copy (B, D, J.Member (D, J.Root (D), "arguments"));
                     S.Initialize := US.To_Unbounded_String (J.Result (B));
                  end if;
               end;
               Respond (S, Seq, Name, True, Body_Of =>
                 "{""supportsConfigurationDoneRequest"":true,"
                 & """supportsFunctionBreakpoints"":true,"
                 & """supportsConditionalBreakpoints"":true,"
                 & """supportsEvaluateForHovers"":true,"
                 & """supportsExceptionInfoRequest"":true,"
                 & """supportsTerminateRequest"":true,"
                 & """exceptionBreakpointFilters"":[]}");
            elsif Name in "launch" | "attach" then
               Start_Session (S, D, Seq, Name, Files, Tools);
            elsif Name = "disconnect" then
               if S.Started and then S.Kind = LLDB then
                  Relay_To_LLDB (S, D, Seq, Name);
               else
                  if S.Started then
                     declare
                        Class, Results : US.Unbounded_String;
                        Arguments : constant J.Value :=
                          J.Member (D, J.Root (D), "arguments");
                        Ending : constant Boolean :=
                          (if J.Is_Present (J.Member
                                (D, Arguments, "terminateDebuggee"))
                           then Flag_Of (D, Arguments, "terminateDebuggee")
                           else not S.Attached);
                     begin
                        Command (S, Console (if Ending then "kill"
                                             else "detach"), Class, Results);
                        Command (S, "-gdb-exit", Class, Results);
                     exception
                        when Debugger_Ended => null;
                     end;
                  end if;
                  Finish;
                  Respond (S, Seq, Name, True);
                  S.Finished := True;
               end if;
            elsif not S.Started then
               Respond (S, Seq, Name, False,
                        (if Name in "setBreakpoints" | "setFunctionBreakpoints"
                           | "setExceptionBreakpoints" | "configurationDone"
                         then Name & " comes after launch or attach"
                         else "no program is being debugged: send launch or"
                           & " attach first"));
            elsif S.Kind = LLDB then
               Relay_To_LLDB (S, D, Seq, Name);
            else
               Answer_GDB (S, D, Seq, Name, Files);
            end if;
         exception
            when Error : No_Answer =>
               Respond (S, Seq, Name, False, "the debugger did not answer "
                        & Ada.Exceptions.Exception_Message (Error)
                        & " within" & Duration'Image (Answer_Limit)
                        & " seconds");
         end;
      end Request;

   begin
      S.Library := US.To_Unbounded_String (Library);
      Status := 0;
      loop
         exit when S.Finished;
         --  What arrived while a request waited comes first.
         if S.Started and then S.Kind = GDB then
            Drain_GDB (S, Files);
         end if;
         while S.Started and then S.Kind = LLDB
           and then not S.Relay_Queue.Is_Empty
         loop
            declare
               Text : constant String := S.Relay_Queue.First_Element;
            begin
               S.Relay_Queue.Delete_First;
               Relay_To_Client (S, Text, Files);
            end;
         end loop;
         exit when S.Finished;
         declare
            From_Debugger, From_Editor : Boolean := False;
            Channel : Debugger_Channel (S'Unchecked_Access);
         begin
            if Transport.Waiting (S.Client_Reader, Client) then
               From_Editor := True;
            elsif S.Started and then S.Kind = LLDB
              and then Transport.Waiting (S.Relay_Reader, Channel)
            then
               From_Debugger := True;
            elsif S.Started then
               Wait_For (S, -1.0, From_Debugger, From_Editor);
            else
               From_Editor := True;
            end if;
            if From_Debugger then
               begin
                  if S.Kind = GDB then
                     declare
                        Lines : Text_Vectors.Vector;
                     begin
                        Read_Lines (S, Lines);
                        for Line of Lines loop
                           Keep (S, Line);
                        end loop;
                     end;
                  else
                     Relay_To_Client (S, Next_From_LLDB (S), Files);
                  end if;
               exception
                  when Debugger_Ended =>
                     Finish;
                     Event (S, "terminated");
               end;
            end if;
            if From_Editor then
               declare
                  Outcome : Transport.Status;
                  Body_Of, Fault : US.Unbounded_String;
               begin
                  Transport.Next (S.Client_Reader, Client, Outcome, Body_Of,
                                  Fault);
                  case Outcome is
                     when Transport.Message =>
                        begin
                           Request (US.To_String (Body_Of));
                        exception
                           when Debugger_Ended =>
                              Finish;
                              Event (S, "terminated");
                        end;
                     when Transport.Too_Long =>
                        null;
                     when Transport.Ended =>
                        exit;
                     when Transport.Broken =>
                        Client.Log ("refine-dap: " & US.To_String (Fault));
                        Status := 1;
                        exit;
                  end case;
               end;
            end if;
         end;
      end loop;
      Finish;
   end Serve;

end Landin.Adapter.Sessions;
