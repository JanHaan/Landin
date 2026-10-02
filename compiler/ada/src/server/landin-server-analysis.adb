with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Fixed;

with Landin.Checking;
with Landin.Configuration;
with Landin.Diagnostics.Lexical;
with Landin.Driver.Checking;
with Landin.Driver.Loading;
with Landin.Panics;
with Landin.Platform.Overlays;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Syntax.Parser;
with Landin.Tokens;
with Landin.Tokens.Lexer;

package body Landin.Server.Analysis is

   package Unbounded renames Ada.Strings.Unbounded;
   package Diag renames Landin.Diagnostics;

   use type Diag.Severity;
   use type Landin.Platform.List_Status;
   use type Landin.Platform.Read_Status;
   use type Landin.Source.Source_Id;
   use type Holes.Verdict;

   package Plan_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Holes.Plan, "=" => Holes."=");

   --  What Path holds, planned once.
   procedure Plan_Source
     (Host  : Landin.Platform.Filesystem'Class;
      Path  : String;
      Plans : in out Plan_Maps.Map);

   procedure Plan_Source
     (Host  : Landin.Platform.Filesystem'Class;
      Path  : String;
      Plans : in out Plan_Maps.Map)
   is
      Content : Unbounded.Unbounded_String;
      Status  : Landin.Platform.Read_Status;
   begin
      if Plans.Contains (Path) then
         return;
      end if;
      Host.Read_File (Path, Content, Status);
      if Status = Landin.Platform.Read_Ok then
         Plans.Insert
           (Path, Holes.Plan_For (Unbounded.To_String (Content)));
      end if;
   end Plan_Source;

   --  Every source directly in Directory, planned.
   procedure Plan_Directory
     (Host      : Landin.Platform.Filesystem'Class;
      Directory : String;
      Plans     : in out Plan_Maps.Map);

   procedure Plan_Directory
     (Host      : Landin.Platform.Filesystem'Class;
      Directory : String;
      Plans     : in out Plan_Maps.Map)
   is
      Entries : Landin.Platform.Path_List;
      Listed  : Landin.Platform.List_Status;
   begin
      Host.List_Directory (Directory, Entries, Listed);
      if Listed = Landin.Platform.List_Ok then
         for Name of Entries loop
            declare
               Path : constant String :=
                 Landin.Driver.Loading.Joined_Path (Directory, Name);
            begin
               if Landin.Driver.Loading.Is_Source_Name (Name)
                 and then not Host.Is_Directory (Path)
               then
                  Plan_Source (Host, Path, Plans);
               end if;
            end;
         end loop;
      end if;
   end Plan_Directory;

   --  The scan's and the parse's report on Text, as the syntax stage makes
   --  it, sorted, and moved onto Id.
   procedure Syntax_Of
     (Name : String;
      Text : String;
      Id   : Landin.Source.Source_Id;
      Into : in out Diag.Diagnostic_List);

   procedure Syntax_Of
     (Name : String;
      Text : String;
      Id   : Landin.Source.Source_Id;
      Into : in out Diag.Diagnostic_List)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
      Found   : Diag.Diagnostic_List;
      Own     : constant Landin.Source.Source_Id := Sources.Add (Name, Text);
   begin
      Landin.Tokens.Lexer.Lex (Sources.Get (Own), Names, Stream);
      Diag.Lexical.Report (Stream, Found);
      declare
         Tree : constant Landin.Syntax.Tree :=
           Landin.Syntax.Parser.Parse (Stream, Names, Found);
         pragma Unreferenced (Tree);
         Ordered : constant Diag.Diagnostic_List := Diag.Sorted (Found);
      begin
         for Position in 1 .. Ordered.Count loop
            Into.Append (Diag.Retargeted (Ordered.Get (Position), Id));
         end loop;
      end;
   end Syntax_Of;

   --  Whether a stage before the checker refused something: the scan, the
   --  parse, the configuration or names, each of which stops the run before
   --  the checker has typed anything.  A code says where it was born and
   --  not which stage raised it, so the stages are asked by their tables:
   --  resolution prepared its table only if every earlier stage passed,
   --  and the checker its own only if resolution did.
   function Has_Frontend_Error
     (Context : in out Landin.Stages.Compilation) return Boolean
     is (not Landin.Resolution.Is_Prepared
               (Landin.Stages.Meanings (Context).all)
         or else not Landin.Checking.Is_Prepared
               (Landin.Stages.Types (Context).all));

   procedure Analyse
     (Context : in out Landin.Stages.Compilation;
      Host    : Landin.Platform.Filesystem'Class;
      Asked   : Request;
      Answer  : out Result)
   is
      Plans  : Plan_Maps.Map;
      Panic  : Landin.Panics.Plan;
      Rooted : constant Boolean :=
        Unbounded.Length (Asked.Entry_Directory) > 0;
      Entry_Directory : constant String :=
        Unbounded.To_String (Asked.Entry_Directory);
      Standing : Boolean := False;
      Missing : aliased Landin.Platform.Path_List;
   begin
      Answer := (others => <>);
      for Option of Asked.Options loop
         declare
            Separator : constant Natural :=
              Ada.Strings.Fixed.Index (Option, "=");
         begin
            Landin.Configuration.Add_Override
              (Landin.Stages.Configurations (Context).all,
               Option (Option'First .. Separator - 1),
               Option (Separator + 1 .. Option'Last));
         end;
      end loop;

      --  The entry module's sources, or the named files, are planned
      --  before anything is loaded.  An imported module is not: its
      --  errors are reported where `refine` reports them, at the import
      --  that reached it, and a stand-in there would hide a broken
      --  library behind a working one.
      if Rooted then
         Plan_Directory (Host, Entry_Directory, Plans);
      else
         for Path of Asked.Files loop
            Plan_Source (Host, Path, Plans);
         end loop;
      end if;

      --  A stand-in is analysed only when every planned source that has
      --  an error has one.
      declare
         Refusing : Boolean := False;
      begin
         for Plan of Plans loop
            Standing := Standing or else Plan.Outcome = Holes.Stood_In;
            Refusing := Refusing or else Plan.Outcome = Holes.Refused;
         end loop;
         if Refusing then
            Standing := False;
         end if;
      end;

      declare
         Stand_In : Landin.Platform.Overlays.Overlay (Host'Access);
      begin
         if Standing then
            for Position in Plans.Iterate loop
               if Plan_Maps.Element (Position).Outcome = Holes.Stood_In then
                  Stand_In.Hold
                    (Plan_Maps.Key (Position),
                     Plan_Maps.Element (Position).Text);
               end if;
            end loop;
         end if;

         if Rooted then
            Landin.Driver.Loading.Load_Reachable_Program
              (Context, Stand_In, Asked.Roots, Entry_Directory,
               Missing'Access);
         else
            Landin.Driver.Loading.Load_Files (Context, Stand_In, Asked.Files);
         end if;
         if Landin.Stages.Source_Count (Context) > 0
           and then not Landin.Stages.Failed (Context)
         then
            Landin.Driver.Checking.Run (Context, Panic);
            --  Names and types exist only where every frontend stage ran,
            --  which is exactly when nothing before the checker refused.
            Answer.Checked := not Has_Frontend_Error (Context);
         end if;
      end;
      Answer.Missing_Directories := Missing;

      --  Each source's held regions, by its identity in this compilation.
      for Index in 1 .. Landin.Stages.Source_Count (Context) loop
         declare
            Id   : constant Landin.Source.Source_Id :=
              Landin.Stages.Nth_Source (Context, Index);
            Name : constant String := Landin.Source.Name
              (Landin.Stages.Source (Context, Id).Element.all);
            Held : Holes.Span_List;
         begin
            if Standing and then Plans.Contains (Name) then
               Held := Plans.Element (Name).Held;
            end if;
            Answer.Held.Append (Held);
         end;
      end loop;

      --  The report: every stood-in source's own syntax errors, then
      --  whatever the compilation reported that touches no held region.
      declare
         Report : constant Diag.Diagnostic_List :=
           Landin.Stages.Report (Context);
         Merged : Diag.Diagnostic_List;
      begin
         if Standing then
            for Index in 1 .. Landin.Stages.Source_Count (Context) loop
               declare
                  Id   : constant Landin.Source.Source_Id :=
                    Landin.Stages.Nth_Source (Context, Index);
                  Name : constant String := Landin.Source.Name
                    (Landin.Stages.Source (Context, Id).Element.all);
               begin
                  if Plans.Contains (Name)
                    and then Plans.Element (Name).Outcome = Holes.Stood_In
                  then
                     declare
                        Content : Unbounded.Unbounded_String;
                        Status  : Landin.Platform.Read_Status;
                     begin
                        Host.Read_File (Name, Content, Status);
                        if Status = Landin.Platform.Read_Ok then
                           Syntax_Of
                             (Name, Unbounded.To_String (Content), Id,
                              Merged);
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end if;
         for Position in 1 .. Report.Count loop
            declare
               Item : constant Diag.Diagnostic := Report.Get (Position);
               Touches : Boolean := Is_Held
                 (Answer,
                  Diag.Source_Of (Diag.Primary (Item)),
                  Diag.Span_Of (Diag.Primary (Item)));
            begin
               for Label in 1 .. Diag.Label_Count (Item) loop
                  Touches := Touches or else Is_Held
                    (Answer,
                     Diag.Source_Of (Diag.Nth_Label (Item, Label)),
                     Diag.Span_Of (Diag.Nth_Label (Item, Label)));
               end loop;
               --  D251: a warning is the compiler's judgement of a program
               --  it accepted, and a source with a hole is not one.
               if not Touches
                 and then not (Standing
                               and then Diag.Level (Item) = Diag.Warning)
               then
                  Merged.Append (Item);
               end if;
            end;
         end loop;
         Answer.Found := Diag.Sorted (Merged);
      end;
   end Analyse;

   function Is_Held
     (Answer : Result;
      Source : Landin.Source.Source_Id;
      Where  : Landin.Source.Span) return Boolean
     is (Source /= Landin.Source.No_Source
         and then Natural (Source) <= Natural (Answer.Held.Length)
         and then Holes.Within
           (Answer.Held.Element (Natural (Source)), Where));

end Landin.Server.Analysis;
