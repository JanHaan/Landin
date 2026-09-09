with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Driver;
with Landin.Platform;
with Landin.Testing.Fakes;

package body Landin.Tests.Optimization_Driver_Suite is
   package US renames Ada.Strings.Unbounded;
   Source : constant String :=
     "public main: () -> (code: i32) = code = 0 end main";

   type Report_Refusing_Host is new
     Landin.Testing.Fakes.Fake_Filesystem with null record;
   overriding procedure Write_File
     (Host : Report_Refusing_Host; Path : String; Content : String;
      Status : out Landin.Platform.Write_Status);

   overriding procedure Write_File
     (Host : Report_Refusing_Host; Path : String; Content : String;
      Status : out Landin.Platform.Write_Status) is
   begin
      if Path = "report.json" then
         Status := Landin.Platform.Not_Writable;
      else
         Landin.Testing.Fakes.Write_File
           (Landin.Testing.Fakes.Fake_Filesystem (Host),
            Path, Content, Status);
      end if;
   end Write_File;

   function Request return Landin.Platform.Path_List;

   function Request return Landin.Platform.Path_List is
      Result : Landin.Platform.Path_List;
   begin
      Result.Append ("main.ldn");
      Result.Append ("--emit=asm");
      Result.Append ("-o");
      Result.Append ("out.s");
      return Result;
   end Request;

   procedure Invalid_Requests (Item : in out Landin.Testing.Context);
   procedure Reports_Are_Deterministic
     (Item : in out Landin.Testing.Context);
   procedure Report_Failures (Item : in out Landin.Testing.Context);
   procedure Tool_Completion (Item : in out Landin.Testing.Context);
   procedure Path_Bytes (Item : in out Landin.Testing.Context);

   procedure Invalid_Requests (Item : in out Landin.Testing.Context) is
      procedure Refuses (First : String; Second : String := "");

      procedure Refuses (First : String; Second : String := "") is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List := Request;
         Result : Landin.Driver.Outcome;
      begin
         Host.Add_File ("main.ldn", Source);
         Host.Add_Alias ("./out.s", "out.s");
         Host.Add_Alias ("a/../main.ldn", "main.ldn");
         Args.Append (First);
         if Second /= "" then
            Args.Append (Second);
         end if;
         Result := Landin.Driver.Execute (Args, Host, Tools);
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Misuse,
            First & " " & Second & " is request misuse");
         Landin.Testing.Check
           (Item, Host.Written ("out.s") = "", "misuse writes no assembly");
         Landin.Testing.Check_Equal
           (Item, Tools.Run_Count, 0, "misuse invokes no tool");
      end Refuses;
   begin
      Refuses ("--optimize=");
      Refuses ("--optimize=SIZE");
      Refuses ("--optimize=size", "--optimize=size");
      Refuses ("--specialize=always");
      Refuses ("--specialize=off", "--specialize=all");
      Refuses ("--build-report=");
      Refuses ("--build-report=a.json", "--build-report=b.json");
      Refuses ("--optimize=size", "--help");
      Refuses ("--specialize=auto", "--identify");
      Refuses ("--build-report=./out.s");
      Refuses ("--build-report=a/../main.ldn");
      Refuses ("--build-report=" & Landin.Driver.Source_Map_Beside ("out.s"));
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List :=
           Landin.Platform.Arguments ("--build-report=report.json");
         Result : Landin.Driver.Outcome;
      begin
         Host.Add_File ("main.ldn", Source);
         Args.Append ("main.ldn");
         Result := Landin.Driver.Execute (Args, Host, Tools);
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Misuse,
            "a report needs an emitted artifact");
      end;
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List;
         Result : Landin.Driver.Outcome;
      begin
         Host.Add_Directory ("app");
         Host.Add_File ("app/main.ldn", Source);
         Host.Add_Alias ("./app//main.ldn", "app/main.ldn");
         Args.Append ("app");
         Args.Append ("--root=lib");
         Args.Append ("--emit=asm");
         Args.Append ("-o");
         Args.Append ("out.s");
         Args.Append ("--build-report=./app//main.ldn");
         Result := Landin.Driver.Execute (Args, Host, Tools);
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Misuse,
            "discovered rooted sources are collision protected");
         Landin.Testing.Check
           (Item, Host.Written ("out.s") = "" and then Tools.Run_Count = 0,
            "rooted collision precedes every artifact and tool");
      end;
      for Kind in 1 .. 3 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List := Request;
            Result : Landin.Driver.Outcome;
            Target : constant String :=
              (case Kind is
                  when 1 => "main.ldn",
                  when 2 => "out.s",
                  when others => Landin.Driver.Source_Map_Beside ("out.s"));
         begin
            Host.Add_File ("main.ldn", Source);
            Host.Add_Alias ("linked-report.json", Target);
            Args.Append ("--build-report=linked-report.json");
            Result := Landin.Driver.Execute (Args, Host, Tools);
            Landin.Testing.Check
              (Item, Result.Status = Landin.Driver.Status_Misuse
               and then Host.Written ("out.s") = ""
               and then Host.Written ("linked-report.json") = ""
               and then Tools.Run_Count = 0,
               "platform identity aliases are refused before every write");
         end;
      end loop;
   end Invalid_Requests;

   procedure Reports_Are_Deterministic
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List := Request;
      Result : Landin.Driver.Outcome;
      First : US.Unbounded_String;
      First_Assembly : US.Unbounded_String;
   begin
      Host.Add_File ("main.ldn", Source);
      Args.Append ("--build-report=report.json");
      Result := Landin.Driver.Execute (Args, Host, Tools);
      Landin.Testing.Check_Equal
        (Item, Result.Status, 0, "default optimized assembly emits");
      First := US.To_Unbounded_String (Host.Written ("report.json"));
      First_Assembly := US.To_Unbounded_String (Host.Written ("out.s"));
      Landin.Testing.Check
        (Item, US.Length (First) > 0, "the report was actually written");
      Landin.Testing.Check
        (Item, Ada.Strings.Fixed.Index
           (US.To_String (First), """path_hex"":""6d61696e2e6c646e""") > 0,
         "report preserves source path bytes");
      Result := Landin.Driver.Execute (Args, Host, Tools);
      Landin.Testing.Check_Equal
        (Item, Result.Status, 0, "repeat emits");
      Landin.Testing.Check_Equal
        (Item, Host.Written ("report.json"), US.To_String (First),
         "equivalent requests have byte-identical reports");
      Landin.Testing.Check_Equal
        (Item, Host.Written ("out.s"), US.To_String (First_Assembly),
         "equivalent requests have byte-identical assembly");
      Args.Append ("--optimize=size");
      Args.Append ("--specialize=auto");
      Args.Append ("--build-mode=release");
      Result := Landin.Driver.Execute (Args, Host, Tools);
      Landin.Testing.Check_Equal
        (Item, Result.Status, 0, "build mode is independent");
      Landin.Testing.Check_Equal
        (Item, Host.Written ("report.json"), US.To_String (First),
         "explicit defaults and build mode do not change optimization");
   end Reports_Are_Deterministic;

   procedure Report_Failures (Item : in out Landin.Testing.Context) is
      Host : Report_Refusing_Host;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List := Request;
      Result : Landin.Driver.Outcome;
   begin
      Host.Add_File ("main.ldn", Source);
      Args.Append ("--build-report=report.json");
      Result := Landin.Driver.Execute (Args, Host, Tools);
      Landin.Testing.Check_Equal
        (Item, Result.Status, Landin.Driver.Status_Reported,
         "report write failure fails compilation");
      Landin.Testing.Check
        (Item, Host.Written ("out.s") /= "",
         "the injected failure is specifically the report write");
      Landin.Testing.Check
        (Item, Ada.Strings.Fixed.Index
           (US.To_String (Result.Report), "cannot write: report.json") > 0,
         "report failure uses the ordinary platform diagnostic");
   end Report_Failures;

   procedure Tool_Completion (Item : in out Landin.Testing.Context) is
   begin
      for Attempt in 0 .. 3 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
            Result : Landin.Driver.Outcome;
         begin
            Host.Add_File ("main.ldn", Source);
            Tools.Set_Result
              ((if Attempt = 1 then 1 else 0), "",
               (if Attempt = 2 then Landin.Platform.Signaled
                elsif Attempt = 3 then Landin.Platform.Timed_Out
                else Landin.Platform.Exited));
            Args.Append ("main.ldn");
            Args.Append ("--emit=exe");
            Args.Append ("-o");
            Args.Append ("program");
            Args.Append ("--build-report=report.json");
            Args.Append ("--optimize=none");
            Args.Append ("--specialize=all");
            Result := Landin.Driver.Execute (Args, Host, Tools);
            Landin.Testing.Check_Equal
              (Item, Tools.Run_Count, 1, "executable invokes one tool");
            Landin.Testing.Check_Equal
              (Item, Result.Status, (if Attempt = 0 then 0 else 1),
               "report outcome follows tool completion");
            Landin.Testing.Check
              (Item, (Host.Written ("report.json") /= "") = (Attempt = 0),
               "only successful tool completion writes evidence");
         end;
      end loop;
   end Tool_Completion;

   procedure Path_Bytes (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
      Result : Landin.Driver.Outcome;
      Path : constant String := "q""" & Character'Val (255) & ".ldn";
   begin
      Host.Add_File (Path, Source);
      Args.Append (Path);
      Args.Append ("--emit=asm");
      Args.Append ("--build-report=report.json");
      Result := Landin.Driver.Execute (Args, Host, Tools);
      Landin.Testing.Check_Equal
        (Item, Result.Status, 0, "arbitrary path bytes do not break JSON");
      Landin.Testing.Check
        (Item, Ada.Strings.Fixed.Index
           (Host.Written ("report.json"), "7122ff2e6c646e") > 0,
         "quotes and non-UTF-8 path bytes are represented exactly");
   end Path_Bytes;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "opt driver", "invalid actions and collisions",
         Invalid_Requests'Access);
      Landin.Testing.Register
        (Into, "opt driver", "deterministic source reports and defaults",
         Reports_Are_Deterministic'Access);
      Landin.Testing.Register
        (Into, "opt driver", "report writes fail through the platform",
         Report_Failures'Access);
      Landin.Testing.Register
        (Into, "opt driver", "reports follow successful tool completion",
         Tool_Completion'Access);
      Landin.Testing.Register
        (Into, "opt driver", "source path bytes survive JSON",
         Path_Bytes'Access);
   end Register;
end Landin.Tests.Optimization_Driver_Suite;
