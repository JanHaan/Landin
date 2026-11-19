--  `refine-dap` on the fake host (D1523-D1527).
--
--  The editor is a scripted channel, and the debugger a scripted session
--  that answers GDB/MI commands, or lldb-dap's requests, from a table.
--  What is held: which debugger a program takes, how library paths map,
--  how GDB's records are read, what a GDB session sends and answers, how
--  lldb-dap's messages are relayed and renumbered, how a panic_handler's
--  stop is described from the source table, and every refusal.  The
--  scripted sessions over real GDB and LLDB are
--  compiler/tests/dap/session.py's.

with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with GNAT.SHA256;

with Landin.Adapter.MI;
with Landin.Adapter.Sessions;
with Landin.Json;
with Landin.Platform;
with Landin.Server.Transport;
with Landin.Testing.Fakes;

package body Landin.Tests.Dap_Suite is

   package US renames Ada.Strings.Unbounded;
   package P renames Landin.Platform;
   package J renames Landin.Json;
   package MI renames Landin.Adapter.MI;
   package Sessions renames Landin.Adapter.Sessions;
   package Fakes renames Landin.Testing.Fakes;
   use type Sessions.Debugger_Kind;
   use type MI.Record_Kind;

   LF : constant Character := ASCII.LF;

   function Contains (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Count (Text, Part : String) return Natural is
     (Ada.Strings.Fixed.Count (Text, Part));

   ---------------------------------------------------------------------
   --  A scripted debugger
   ---------------------------------------------------------------------

   type Answer is record
      Prefix : US.Unbounded_String;
      Reply  : US.Unbounded_String;
      Used   : Boolean := False;
   end record;

   package Answer_Vectors is new Ada.Containers.Vectors (Positive, Answer);

   --  GDB answers a command line from the first unused answer whose
   --  prefix it begins with, %T in the reply standing for its token, and
   --  with `^done` when none does.  lldb-dap answers a request from the
   --  first unused answer whose prefix is its command: the reply's first
   --  line is the response's body, or empty, and each later line an event
   --  sent after it.
   type Fake_Debugger is limited new P.Debugger_Session with record
      Relay    : Boolean := False;
      Refuse   : Boolean := False;
      Answers  : Answer_Vectors.Vector;
      Sent     : US.Unbounded_String;
      Output   : US.Unbounded_String;
      Program  : US.Unbounded_String;
      Started  : US.Unbounded_String;
      Settings : US.Unbounded_String;
      Pipes    : Boolean := False;
      Stopped  : Boolean := False;
   end record;

   overriding procedure Start
     (Host          : in out Fake_Debugger;
      Arguments     : P.Path_List;
      Settings      : P.Path_List;
      Program_Pipes : Boolean;
      Failure       : out US.Unbounded_String);
   overriding function Variable
     (Host : Fake_Debugger; Name : String) return String;
   overriding procedure Wait
     (Host   : in out Fake_Debugger;
      Client : in out P.Channel'Class;
      Limit  : Duration;
      Ready  : out P.Ready_Streams);
   overriding procedure Read
     (Host : in out Fake_Debugger;
      From : P.Session_Input;
      Into : out String;
      Last : out Natural);
   overriding procedure Send
     (Host : in out Fake_Debugger;
      Item : String;
      Sent : out Boolean);
   overriding procedure Stop
     (Host   : in out Fake_Debugger;
      Grace  : Duration;
      Status : out Integer);

   procedure Answer_With
     (Host : in out Fake_Debugger'Class; Prefix, Reply : String);
   procedure Answer_With
     (Host : in out Fake_Debugger'Class; Prefix, Reply : String) is
   begin
      Host.Answers.Append
        (Answer'(Prefix => US.To_Unbounded_String (Prefix),
                 Reply => US.To_Unbounded_String (Reply), Used => False));
   end Answer_With;

   function Reply_For (Host : in out Fake_Debugger'Class; Command : String)
     return String;
   function Reply_For (Host : in out Fake_Debugger'Class; Command : String)
     return String is
   begin
      for Index in 1 .. Natural (Host.Answers.Length) loop
         declare
            Item : Answer := Host.Answers (Index);
            Prefix : constant String := US.To_String (Item.Prefix);
         begin
            if not Item.Used and then Command'Length >= Prefix'Length
              and then Command (Command'First
                                .. Command'First + Prefix'Length - 1)
                = Prefix
            then
               Item.Used := True;
               Host.Answers.Replace_Element (Index, Item);
               return US.To_String (Item.Reply);
            end if;
         end;
      end loop;
      return (if Host.Relay then "" else "%T^done");
   end Reply_For;

   function Replaced (Text, Token : String) return String;
   function Replaced (Text, Token : String) return String is
      At_Mark : constant Natural := Ada.Strings.Fixed.Index (Text, "%T");
   begin
      return (if At_Mark = 0 then Text
              else Text (Text'First .. At_Mark - 1) & Token
                & Replaced (Text (At_Mark + 2 .. Text'Last), Token));
   end Replaced;

   overriding procedure Start
     (Host          : in out Fake_Debugger;
      Arguments     : P.Path_List;
      Settings      : P.Path_List;
      Program_Pipes : Boolean;
      Failure       : out US.Unbounded_String) is
   begin
      Host.Started := US.To_Unbounded_String (P.Joined (Arguments));
      Host.Settings := US.To_Unbounded_String (P.Joined (Settings));
      Host.Pipes := Program_Pipes;
      Failure := (if Host.Refuse
                  then US.To_Unbounded_String ("no such program")
                  else US.Null_Unbounded_String);
   end Start;

   overriding function Variable
     (Host : Fake_Debugger; Name : String) return String is
     (if Name = "SHELL" then "/bin/zsh" else "");

   overriding procedure Wait
     (Host   : in out Fake_Debugger;
      Client : in out P.Channel'Class;
      Limit  : Duration;
      Ready  : out P.Ready_Streams)
   is
      pragma Unreferenced (Limit);
   begin
      Ready := [others => False];
      Ready (P.Debugger) := US.Length (Host.Output) > 0;
      Ready (P.Program_Output) := US.Length (Host.Program) > 0;
      --  With nothing to say, the scripted editor speaks next, which at
      --  the script's end is its end.
      Ready (P.Editor) := Client.Pending
        or else not (Ready (P.Debugger) or else Ready (P.Program_Output));
   end Wait;

   overriding procedure Read
     (Host : in out Fake_Debugger;
      From : P.Session_Input;
      Into : out String;
      Last : out Natural)
   is
      use type P.Session_Stream;

      procedure Take (Source : in out US.Unbounded_String);
      procedure Take (Source : in out US.Unbounded_String) is
         Count : constant Natural :=
           Natural'Min (Into'Length, US.Length (Source));
      begin
         Into (Into'First .. Into'First + Count - 1) :=
           US.Slice (Source, 1, Count);
         US.Delete (Source, 1, Count);
         Last := Into'First + Count - 1;
      end Take;
   begin
      if From = P.Program_Errors then
         Last := Into'First - 1;
      elsif From = P.Debugger then
         Take (Host.Output);
      else
         Take (Host.Program);
      end if;
   end Read;

   overriding procedure Send
     (Host : in out Fake_Debugger;
      Item : String;
      Sent : out Boolean) is
   begin
      Sent := True;
      if not Host.Relay then
         declare
            First : Positive := Item'First;
         begin
            for Index in Item'Range loop
               if Item (Index) = LF then
                  declare
                     Line : constant String := Item (First .. Index - 1);
                     Digits_End : Natural := Line'First - 1;
                  begin
                     while Digits_End < Line'Last
                       and then Line (Digits_End + 1) in '0' .. '9'
                     loop
                        Digits_End := Digits_End + 1;
                     end loop;
                     declare
                        Token : constant String :=
                          Line (Line'First .. Digits_End);
                        Command : constant String :=
                          Line (Digits_End + 1 .. Line'Last);
                     begin
                        US.Append (Host.Sent, Command & LF);
                        US.Append (Host.Output, Replaced
                          (Reply_For (Host, Command), Token) & LF);
                     end;
                  end;
                  First := Index + 1;
               end if;
            end loop;
         end;
         return;
      end if;
      declare
         Header_End : constant Natural :=
           Ada.Strings.Fixed.Index (Item, ASCII.CR & LF & ASCII.CR & LF);
         D : J.Document;
      begin
         J.Parse (D, Item (Header_End + 4 .. Item'Last));
         declare
            Root : constant J.Value := J.Root (D);
            Command : constant String :=
              J.Text (D, J.Member (D, Root, "command"));
            Seq : constant String := J.Text (D, J.Member (D, Root, "seq"));
            Arguments : J.Builder;
            Reply : constant String := Reply_For (Host, Command);
            Line_End : constant Natural :=
              Ada.Strings.Fixed.Index (Reply & LF, "" & LF);
            First_Line : constant String :=
              Reply (Reply'First .. Line_End - 1);
            Rest : constant String :=
              (if Line_End > Reply'Last then ""
               else Reply (Line_End + 1 .. Reply'Last));
         begin
            J.Copy (Arguments, D, J.Member (D, Root, "arguments"));
            US.Append (Host.Sent, Command & " " & J.Result (Arguments) & LF);
            US.Append (Host.Output, Landin.Server.Transport.Framed
              ("{""seq"":0,""type"":""response"",""request_seq"":" & Seq
               & ",""success"":true,""command"":""" & Command & """"
               & (if First_Line = "" then ""
                  else ",""body"":" & First_Line) & "}"));
            declare
               First : Positive := Rest'First;
            begin
               for Index in Rest'First .. Rest'Last + 1 loop
                  if Index > Rest'Last or else Rest (Index) = LF then
                     if Index > First then
                        US.Append (Host.Output, Landin.Server.Transport.Framed
                          (Rest (First .. Index - 1)));
                     end if;
                     First := Index + 1;
                  end if;
               end loop;
            end;
         end;
      end;
   end Send;

   overriding procedure Stop
     (Host   : in out Fake_Debugger;
      Grace  : Duration;
      Status : out Integer)
   is
      pragma Unreferenced (Grace);
   begin
      Host.Stopped := True;
      Status := 0;
   end Stop;

   ---------------------------------------------------------------------
   --  An editor's script
   ---------------------------------------------------------------------

   function Request (Seq : Positive; Command : String;
                     Arguments : String := "{}") return String is
     (Landin.Server.Transport.Framed
        ("{""seq"":" & Ada.Strings.Fixed.Trim (Seq'Image, Ada.Strings.Both)
         & ",""type"":""request"",""command"":""" & Command
         & """,""arguments"":" & Arguments & "}"));

   ELF_Header : constant String :=
     Character'Val (16#7F#) & "ELF" & Character'Val (2) & Character'Val (1)
     & Character'Val (1) & Character'Val (0)
     & Ada.Strings.Fixed."*" (8, Character'Val (0));

   Library : constant String := "/lib/landin";

   --  Serve Script over Debugger with Files, and return what the editor
   --  was sent.
   function Served
     (Script : String; Debugger : aliased in out Fake_Debugger;
      Files : Fakes.Fake_Filesystem; Pauses : String := "")
      return String;
   function Served
     (Script : String; Debugger : aliased in out Fake_Debugger;
      Files : Fakes.Fake_Filesystem; Pauses : String := "")
      return String
   is
      Client : Fakes.Fake_Channel;
      Tools : Fakes.Fake_Tool_Runner;
      Status : Integer;
      First : Positive := Pauses'First;
   begin
      Fakes.Script (Client, Script);
      --  Pauses is a list of request counts: the editor waits after so
      --  many of the script's requests.
      for Index in Pauses'First .. Pauses'Last + 1 loop
         if Index > Pauses'Last or else Pauses (Index) = ' ' then
            if Index > First then
               declare
                  After : constant Positive :=
                    Positive'Value (Pauses (First .. Index - 1));
                  Offset : Natural := Script'First;
               begin
                  for Unused in 1 .. After loop
                     Offset := Ada.Strings.Fixed.Index
                       (Script, "Content-Length", Offset + 1);
                  end loop;
                  Fakes.Pause_At (Client, Offset - Script'First);
               end;
            end if;
            First := Index + 1;
         end if;
      end loop;
      Fakes.Set_Available (Tools, True);
      Sessions.Serve (Client, Debugger, Files, Tools, Library, Status);
      return Fakes.Output (Client);
   end Served;

   ---------------------------------------------------------------------
   --  Cases
   ---------------------------------------------------------------------

   procedure The_Debugger_A_Program_Takes
     (Item : in out Landin.Testing.Context);
   procedure The_Debugger_A_Program_Takes
     (Item : in out Landin.Testing.Context)
   is
      FreeBSD : String := ELF_Header;
      Mach_O : constant String :=
        Character'Val (16#CF#) & Character'Val (16#FA#)
        & Character'Val (16#ED#) & Character'Val (16#FE#);
   begin
      FreeBSD (FreeBSD'First + 7) := Character'Val (9);
      Landin.Testing.Check
        (Item, Sessions.Debugger_For (ELF_Header) = Sessions.GDB,
         "a Linux ELF takes GDB");
      Landin.Testing.Check
        (Item, Sessions.Debugger_For (FreeBSD) = Sessions.LLDB,
         "an ELF whose OSABI is FreeBSD's takes LLDB");
      Landin.Testing.Check
        (Item, Sessions.Debugger_For (Mach_O) = Sessions.LLDB,
         "a Mach-O takes LLDB");
      Landin.Testing.Check
        (Item, Sessions.Debugger_For ("assembly") = Sessions.GDB
         and then Sessions.Debugger_For ("") = Sessions.GDB,
         "anything else takes GDB");
   end The_Debugger_A_Program_Takes;

   procedure Library_Paths_Map_By_Namespace
     (Item : in out Landin.Testing.Context);
   procedure Library_Paths_Map_By_Namespace
     (Item : in out Landin.Testing.Context) is
   begin
      Landin.Testing.Check_Equal
        (Item, Sessions.Local_Path ("/landin-library/core/vec/vec.ldn",
                                    "/repo"),
         "/repo/core/vec/vec.ldn", "a library file is read from the library");
      Landin.Testing.Check_Equal
        (Item, Sessions.Local_Path ("/landin-library/platform/linux/l.ldn",
                                    "/repo"),
         "/repo/platform/linux/l.ldn", "each namespace maps");
      Landin.Testing.Check_Equal
        (Item, Sessions.Local_Path ("/landin-library/core/x.ldn", ""),
         "/landin-library/core/x.ldn", "without a library nothing maps");
      Landin.Testing.Check_Equal
        (Item, Sessions.Local_Path ("/landin-library/tools/x.ldn", "/repo"),
         "/landin-library/tools/x.ldn", "only the three namespaces map");
      Landin.Testing.Check_Equal
        (Item, Sessions.Recorded_Path ("/repo/hosted/io/io.ldn", "/repo"),
         "/landin-library/hosted/io/io.ldn",
         "a library file is named as the debug information records it");
      Landin.Testing.Check_Equal
        (Item, Sessions.Recorded_Path ("/repo/compiler/tests/main.ldn",
                                       "/repo"),
         "/repo/compiler/tests/main.ldn",
         "a checkout's own sources under the library's directory keep"
         & " their paths");
      Landin.Testing.Check_Equal
        (Item, Sessions.Recorded_Path ("/repo/core-extra/a.ldn", "/repo"),
         "/repo/core-extra/a.ldn", "a namespace is a whole directory name");
   end Library_Paths_Map_By_Namespace;

   procedure Records_Are_Read (Item : in out Landin.Testing.Context);
   procedure Records_Are_Read (Item : in out Landin.Testing.Context) is
      Done : constant MI.Line := MI.Parse
        ("12^done,bkpt={number=""1"",addr=""0x40""},stack=[frame={l=""0""},"
         & "frame={l=""1""}],values=[""a"",""b""],x=""1"",x=""2""");
      Stopped : constant MI.Line := MI.Parse
        ("*stopped,reason=""exited"",exit-code=""03""");
      Console : constant MI.Line := MI.Parse
        ("~""tab\there \""quoted\"" \303\251\n""");
   begin
      Landin.Testing.Check
        (Item, Done.Kind = MI.Result and then Done.Token = 12
         and then US.To_String (Done.Class) = "done",
         "a result record keeps its token and class");
      Landin.Testing.Check_Equal
        (Item, US.To_String (Done.Results),
         "{""bkpt"":{""number"":""1"",""addr"":""0x40""},""stack"":"
         & "[{""l"":""0""},{""l"":""1""}],""values"":[""a"",""b""],"
         & """x"":""1"",""x#2"":""2""}",
         "tuples are objects, lists arrays, and a repeated name numbered");
      Landin.Testing.Check
        (Item, Stopped.Kind = MI.Exec and then Stopped.Token = 0
         and then US.To_String (Stopped.Class) = "stopped",
         "an asynchronous record has no token");
      Landin.Testing.Check_Equal
        (Item, US.To_String (Console.Text),
         "tab" & ASCII.HT & "here ""quoted"" "
         & Character'Val (16#C3#) & Character'Val (16#A9#) & LF,
         "a stream's escapes and octal bytes are decoded");
      Landin.Testing.Check
        (Item, MI.Parse ("(gdb) ").Kind = MI.Prompt,
         "the prompt ends a batch");
      Landin.Testing.Check
        (Item, MI.Parse ("Hello, world!").Kind = MI.Other
         and then MI.Parse ("^done,x=").Kind = MI.Other
         and then MI.Parse ("5~""x""").Kind = MI.Other,
         "a line that is not a record is the program's");
      Landin.Testing.Check_Equal
        (Item, MI.Quoted ("a ""b"" \ " & LF), """a \""b\"" \\ \n""",
         "an operand is quoted as a C string");
   end Records_Are_Read;

   procedure A_GDB_Session (Item : in out Landin.Testing.Context);
   procedure A_GDB_Session (Item : in out Landin.Testing.Context) is
      Files : Fakes.Fake_Filesystem;
      Debugger : aliased Fake_Debugger;
      Script : constant String :=
        Request (1, "initialize", "{""adapterID"":""t""}")
        & Request (2, "launch", "{""program"":""app"",""cwd"":""/work"","
                   & """args"":[""a b"",""it's""]}")
        & Request (3, "setBreakpoints",
                   "{""source"":{""path"":""/lib/landin/core/vec/vec.ldn""},"
                   & """breakpoints"":[{""line"":12}]}")
        & Request (4, "configurationDone")
        & Request (5, "stackTrace", "{""threadId"":1}")
        & Request (6, "scopes", "{""frameId"":100000}")
        & Request (7, "variables", "{""variablesReference"":1}")
        & Request (8, "variables", "{""variablesReference"":2}")
        & Request (9, "continue", "{""threadId"":1}")
        & Request (10, "disconnect");
      Frame : constant String :=
        "frame={addr=""0x401000"",func=""push"",file=""vec.ldn"","
        & "fullname=""/landin-library/core/vec/vec.ldn"",line=""12""}";
   begin
      Fakes.Add_File (Files, "/work/app", ELF_Header);
      Answer_With (Debugger, "-break-insert",
                   "%T^done,bkpt={number=""1"",addr=""0x401000"","
                   & "fullname=""/landin-library/core/vec/vec.ldn"","
                   & "line=""12""}");
      Answer_With (Debugger, "-exec-run",
                   "%T^running" & LF & "*running,thread-id=""all"""
                   & LF & "*stopped,reason=""breakpoint-hit"",bkptno=""1"","
                   & Frame & ",thread-id=""1""");
      Answer_With (Debugger, "-stack-list-frames",
                   "%T^done,stack=[frame={level=""0"",addr=""0x401000"","
                   & "func=""push"",file=""vec.ldn"",fullname="
                   & """/landin-library/core/vec/vec.ldn"",line=""12""},"
                   & "frame={level=""1"",addr=""0x402000"",func=""main"","
                   & "file=""main.ldn"",fullname=""/work/main.ldn"","
                   & "line=""7""}]");
      Answer_With (Debugger, "-stack-list-variables",
                   "%T^done,variables=[{name=""count"",type=""u32"","
                   & "value=""3""},{name=""p"",type=""point""}]");
      Answer_With (Debugger, "-var-create",
                   "%T^done,name=""var1"",numchild=""2"",type=""point""");
      Answer_With (Debugger, "-var-list-children",
                   "%T^done,numchild=""2"",children=[child={name="
                   & """var1.x"",exp=""x"",numchild=""0"",value=""3"","
                   & "type=""i32""},child={name=""var1.y"",exp=""y"","
                   & "numchild=""0"",value=""4"",type=""i32""}]");
      Answer_With (Debugger, "-exec-continue",
                   "%T^running" & LF & "@""Hello\n"""
                   & LF & "*stopped,reason=""exited"",exit-code=""03""");
      declare
         Said : constant String := Served (Script, Debugger, Files, "4 9");
         Sent : constant String := US.To_String (Debugger.Sent);
      begin
         Landin.Testing.Check_Equal
           (Item, US.To_String (Debugger.Started),
            "gdb" & LF & "--interpreter=mi3" & LF & "-q" & LF & "-nx" & LF,
            "GDB is started over GDB/MI");
         Landin.Testing.Check
           (Item, Debugger.Pipes
            and then US.To_String (Debugger.Settings) = "SHELL=/bin/sh" & LF,
            "a launched program gets its pipes through /bin/sh");
         Landin.Testing.Check
           (Item, Contains (Sent, "-interpreter-exec console ""set"
                            & " substitute-path /landin-library/core"
                            & " /lib/landin/core""")
            and then Contains (Sent, "/landin-library/platform"
                               & " /lib/landin/platform"),
            "each library namespace is mapped");
         Landin.Testing.Check
           (Item, Contains (Sent, "-environment-cd ""/work""")
            and then Contains (Sent, "-file-exec-and-symbols ""/work/app""")
            and then Contains (Sent, "set environment SHELL=/bin/zsh"),
            "the program is found in its directory, and keeps the"
            & " caller's shell");
         Landin.Testing.Check
           (Item, Contains (Sent, "-exec-arguments 'a b' 'it'\''s'"
                            & " </dev/null >&3 2>&4"),
            "arguments are quoted for the shell, and the output is piped");
         Landin.Testing.Check
           (Item, Contains (Sent, "-break-insert -f"
                            & " ""/landin-library/core/vec/vec.ldn:12"""),
            "a breakpoint in a library file names it as recorded");
         Landin.Testing.Check
           (Item, Contains (Said, """breakpoints"":[{""id"":1,"
                            & """verified"":true,""line"":12}]"),
            "the breakpoint is verified");
         Landin.Testing.Check
           (Item, Contains (Said, """event"":""initialized""")
            and then Contains (Said, """reason"":""breakpoint"",""threadId"""
                               & ":1,""allThreadsStopped"":true,"
                               & """hitBreakpointIds"":[1]"),
            "the stop is a breakpoint's");
         Landin.Testing.Check
           (Item, Contains (Said, """id"":100000,""name"":""push"","
                            & """source"":{""name"":""vec.ldn"",""path"":"
                            & """/lib/landin/core/vec/vec.ldn""}")
            and then Contains (Said, """path"":""/work/main.ldn"""),
            "frames show the library's files where the library is");
         Landin.Testing.Check
           (Item, Contains (Said, "{""name"":""count"",""value"":""3"","
                            & """type"":""u32"",""variablesReference"":0}")
            and then Contains (Said, "{""name"":""p"",""value"":""point"","
                               & """type"":""point"","
                               & """variablesReference"":2}")
            and then Contains (Said, "{""name"":""x"",""value"":""3"","
                               & """type"":""i32"","
                               & """variablesReference"":0}"),
            "locals, and a record's fields through a variable object");
         Landin.Testing.Check
           (Item, Contains (Sent, "-var-delete var1"),
            "variable objects are deleted when the program runs on");
         Landin.Testing.Check
           (Item, Contains (Said, """category"":""stdout"",""output"":"
                            & """Hello\n""")
            and then Contains (Said, """event"":""exited"",""body"":"
                               & "{""exitCode"":3}")
            and then Contains (Said, """event"":""terminated"""),
            "what the program wrote is shown, and its octal status read");
         Landin.Testing.Check
           (Item, Contains (Said, """request_seq"":10,""success"":true,"
                            & """command"":""disconnect""")
            and then Contains (Sent, "-interpreter-exec console ""kill""")
            and then Debugger.Stopped,
            "a disconnect ends what was launched and the debugger");
      end;
   end A_GDB_Session;

   --  A source table for the program "fake program": one file, main.ldn,
   --  whose sites start at 10 and whose second line starts at byte 20.
   procedure Add_Table (Files : in out Fakes.Fake_Filesystem);
   procedure Add_Table (Files : in out Fakes.Fake_Filesystem) is
      Program : constant String := "fake program";
   begin
      Fakes.Add_File (Files, "/work/app", Program);
      Fakes.Add_File
        (Files, "/work/app.sources.json",
         "{""build_id"":""" & Ada.Strings.Fixed."*" (64, 'a')
         & """,""assembly_sha256"":"""
         & GNAT.SHA256.Digest (Program) & """,""files"":[{""file_id"":1,"
         & """path_hex"":""6d61696e2e6c646e"",""panic_base"":10,"
         & """byte_length"":100,""line_offsets"":[0,20,40]}]}");
   end Add_Table;

   procedure A_Panic_Names_Its_Site (Item : in out Landin.Testing.Context);
   procedure A_Panic_Names_Its_Site (Item : in out Landin.Testing.Context)
   is
      Files : Fakes.Fake_Filesystem;
      Debugger : aliased Fake_Debugger;
      --  Byte 25, line 2 column 6, and the check that failed second in
      --  D231's order: 10 + 5 * 25 + 1.
      Script : constant String :=
        Request (1, "initialize")
        & Request (2, "launch", "{""program"":""/work/app""}")
        & Request (3, "configurationDone")
        & Request (4, "exceptionInfo", "{""threadId"":1}")
        & Request (5, "disconnect");
   begin
      Add_Table (Files);
      Answer_With (Debugger, "-exec-run",
                   "%T^running" & LF & "*stopped,reason=""breakpoint-hit"","
                   & "bkptno=""1"",frame={func=""panic_handler""},"
                   & "thread-id=""1""");
      Answer_With (Debugger, "-data-evaluate-expression --thread 1"
                   & " --frame 0 site", "%T^done,value=""136""");
      declare
         Said : constant String := Served (Script, Debugger, Files, "3");
      begin
         Landin.Testing.Check
           (Item, Contains (Said, """reason"":""exception"",""description"""
                            & ":""panic: overflow at main.ldn:2:6"""),
            "a stop in panic_handler is an exception at its site");
         Landin.Testing.Check
           (Item, Contains (Said, """exceptionId"":""overflow"","
                            & """description"":""panic: overflow at"
                            & " main.ldn:2:6"",""breakMode"":""always"""),
            "exceptionInfo names the check that failed");
      end;
      declare
         Missing : Fakes.Fake_Filesystem;
         Again : aliased Fake_Debugger;
      begin
         Fakes.Add_File (Missing, "/work/app", "fake program");
         Answer_With (Again, "-exec-run",
                      "%T^running" & LF & "*stopped,reason=""breakpoint-hit"","
                      & "frame={func=""panic_handler""},thread-id=""1""");
         Answer_With (Again, "-data-evaluate-expression",
                      "%T^done,value=""136""");
         Landin.Testing.Check
           (Item, Contains (Served (Script, Again, Missing, "3"),
                            "panic at site 136, which /work/app.sources.json"
                            & " does not resolve: cannot read the source"
                            & " table /work/app.sources.json: it does not"
                            & " exist; refine compile --panic-map writes it"),
            "without a table the site is named, and how to get one");
      end;
   end A_Panic_Names_Its_Site;

   procedure LLDB_Is_Relayed (Item : in out Landin.Testing.Context);
   procedure LLDB_Is_Relayed (Item : in out Landin.Testing.Context) is
      Files : Fakes.Fake_Filesystem;
      Debugger : aliased Fake_Debugger;
      Script : constant String :=
        Request (1, "initialize", "{""adapterID"":""t""}")
        & Request (2, "launch", "{""program"":""/work/app"","
                   & """stopOnEntry"":false,""debugger"":""lldb"","
                   & """debuggerPath"":""/x/lldb-dap""}")
        & Request (3, "setBreakpoints",
                   "{""source"":{""path"":""/work/main.ldn""},"
                   & """breakpoints"":[{""line"":3}]}")
        & Request (4, "configurationDone")
        & Request (5, "exceptionInfo", "{""threadId"":7}")
        & Request (6, "disconnect");
   begin
      Debugger.Relay := True;
      Add_Table (Files);
      Answer_With (Debugger, "initialize",
                   "{""supportsConfigurationDoneRequest"":true}");
      Answer_With (Debugger, "launch",
                   LF & "{""seq"":0,""type"":""event"","
                   & """event"":""initialized""}");
      Answer_With (Debugger, "setBreakpoints",
                   "{""breakpoints"":[{""id"":1,""verified"":true,"
                   & """line"":3}]}");
      Answer_With (Debugger, "configurationDone",
                   LF & "{""seq"":0,""type"":""event"",""event"":""stopped"","
                   & """body"":{""reason"":""breakpoint"",""threadId"":7}}");
      Answer_With (Debugger, "stackTrace",
                   "{""stackFrames"":[{""id"":5,""name"":""panic_handler"","
                   & """line"":19}]}");
      Answer_With (Debugger, "evaluate", "{""result"":""136"","
                   & """variablesReference"":0}");
      declare
         Said : constant String := Served (Script, Debugger, Files, "4");
         Sent : constant String := US.To_String (Debugger.Sent);
      begin
         Landin.Testing.Check_Equal
           (Item, US.To_String (Debugger.Started), "/x/lldb-dap" & LF,
            "lldb-dap is started as debuggerPath names it");
         Landin.Testing.Check
           (Item, Contains (Sent, "initialize {""adapterID"":""t""}"),
            "lldb-dap is initialized as the editor initialized refine-dap");
         Landin.Testing.Check
           (Item, Contains (Sent, "launch {""stopOnEntry"":false,"
                            & """program"":""/work/app"",""sourceMap"":"
                            & "[[""/landin-library/core"","
                            & """/lib/landin/core""],"
                            & "[""/landin-library/hosted"","
                            & """/lib/landin/hosted""],"
                            & "[""/landin-library/platform"","
                            & """/lib/landin/platform""]]}"),
            "launch is written in lldb-dap's terms, the library mapped");
         Landin.Testing.Check
           (Item, Contains (Said, """request_seq"":2,""success"":true,"
                            & """command"":""launch""")
            and then Contains (Said, """request_seq"":3,""success"":true,"
                               & """command"":""setBreakpoints""")
            and then not Contains (Said, """seq"":0,"),
            "responses answer the editor's own requests, renumbered");
         Landin.Testing.Check
           (Item, Contains (Said, """body"":{""threadId"":7,""reason"":"
                            & """exception"",""description"":""panic:"
                            & " overflow at main.ldn:2:6""")
            and then Contains (Said, """exceptionId"":""overflow"""),
            "a panic_handler's stop is described, and exceptionInfo"
            & " answered here");
         Landin.Testing.Check
           (Item, Contains (Sent, "stackTrace {""threadId"":7,""levels"":1}")
            and then Contains (Sent, "evaluate {""expression"":""site"","
                               & """context"":""watch"",""frameId"":5}")
            and then Count (Said, """command"":""stackTrace""") = 0,
            "the adapter's own questions stay its own");
         Landin.Testing.Check
           (Item, Contains (Said, """request_seq"":6,""success"":true,"
                            & """command"":""disconnect""")
            and then Debugger.Stopped,
            "a disconnect is relayed and ends lldb-dap");
      end;
   end LLDB_Is_Relayed;

   procedure Attach_Reaches_A_Stub (Item : in out Landin.Testing.Context);
   procedure Attach_Reaches_A_Stub (Item : in out Landin.Testing.Context) is
      Files : Fakes.Fake_Filesystem;
      Over_GDB : aliased Fake_Debugger;
      Over_LLDB : aliased Fake_Debugger;
      Script : constant String :=
        Request (1, "initialize")
        & Request (2, "attach", "{""program"":""/work/app"","
                   & """remote"":""/tmp/app.gdb.sock""}")
        & Request (3, "disconnect");
      Remote : constant String :=
        Request (1, "initialize")
        & Request (2, "attach", "{""program"":""/work/app"","
                   & """debugger"":""lldb"",""remote"":""localhost:4321""}")
        & Request (3, "disconnect");
   begin
      Fakes.Add_File (Files, "/work/app", ELF_Header);
      Answer_With (Over_GDB, "-target-select", "%T^connected");
      declare
         Said : constant String := Served (Script, Over_GDB, Files);
         Sent : constant String := US.To_String (Over_GDB.Sent);
      begin
         Landin.Testing.Check
           (Item, Contains (Sent, "-target-select remote"
                            & " ""/tmp/app.gdb.sock""")
            and then not Contains (Sent, "-exec-arguments")
            and then not Over_GDB.Pipes,
            "GDB attaches to the stub, and starts nothing");
         Landin.Testing.Check
           (Item, Contains (Said, """command"":""attach""")
            and then Contains (Sent, "console ""detach"""),
            "an attached program is left running at a disconnect");
      end;
      Over_LLDB.Relay := True;
      declare
         Unused : constant String := Served (Remote, Over_LLDB, Files);
      begin
         Landin.Testing.Check
           (Item, Contains (US.To_String (Over_LLDB.Sent),
                            """gdb-remote-hostname"":""localhost"","
                            & """gdb-remote-port"":4321"),
            "LLDB reaches the stub through lldb-dap's gdb-remote");
      end;
   end Attach_Reaches_A_Stub;

   procedure Refusals_Say_What_To_Do (Item : in out Landin.Testing.Context);
   procedure Refusals_Say_What_To_Do (Item : in out Landin.Testing.Context)
   is
      Files : Fakes.Fake_Filesystem;
      Debugger : aliased Fake_Debugger;
      Script : constant String :=
        Request (1, "initialize")
        & Request (2, "threads")
        & Request (3, "setBreakpoints", "{}")
        & Request (4, "launch", "{}")
        & Request (5, "attach", "{""program"":""/work/app""}")
        & Request (6, "launch", "{""program"":""/work/app"","
                   & """debugger"":""cdb""}")
        & Request (7, "launch", "{""program"":""/work/none""}")
        & Request (8, "launch", "{""program"":""/work/app""}")
        & Request (9, "disconnect");
   begin
      Fakes.Add_File (Files, "/work/app", ELF_Header);
      Debugger.Refuse := True;
      declare
         Said : constant String := Served (Script, Debugger, Files);
      begin
         Landin.Testing.Check
           (Item, Contains (Said, "no program is being debugged: send"
                            & " launch or attach first")
            and then Contains (Said, "setBreakpoints comes after launch or"
                               & " attach"),
            "a request before a program is refused with what comes first");
         Landin.Testing.Check
           (Item, Contains (Said, "launch needs \""program\"", the path of"
                            & " the executable refine compile wrote"),
            "launch names what it needs");
         Landin.Testing.Check
           (Item, Contains (Said, "attach needs \""remote\"", where a"
                            & " debugger stub listens"),
            "attach names what it needs");
         Landin.Testing.Check
           (Item, Contains (Said, "\""debugger\"" is \""gdb\"" or"
                            & " \""lldb\"", not \""cdb\"""),
            "an unknown debugger is refused");
         Landin.Testing.Check
           (Item, Contains (Said, "cannot read the program /work/none: it"
                            & " does not exist"),
            "a missing program is named");
         Landin.Testing.Check
           (Item, Contains (Said, "cannot start GDB as gdb: no such program;"
                            & " name the debugger with \""debuggerPath\"""),
            "a debugger that cannot start says how to name another");
      end;
   end Refusals_Say_What_To_Do;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "dap", "the debugger a program takes",
         The_Debugger_A_Program_Takes'Access);
      Landin.Testing.Register
        (Into, "dap", "library paths map by namespace",
         Library_Paths_Map_By_Namespace'Access);
      Landin.Testing.Register
        (Into, "dap", "GDB/MI records are read", Records_Are_Read'Access);
      Landin.Testing.Register
        (Into, "dap", "a GDB session", A_GDB_Session'Access);
      Landin.Testing.Register
        (Into, "dap", "a panic names its site",
         A_Panic_Names_Its_Site'Access);
      Landin.Testing.Register
        (Into, "dap", "LLDB's adapter is relayed", LLDB_Is_Relayed'Access);
      Landin.Testing.Register
        (Into, "dap", "attach reaches a stub", Attach_Reaches_A_Stub'Access);
      Landin.Testing.Register
        (Into, "dap", "refusals say what to do",
         Refusals_Say_What_To_Do'Access);
   end Register;

end Landin.Tests.Dap_Suite;
