with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Fixed;

with Landin.Checking;
with Landin.Configuration;
with Landin.Diagnostics.Catalogue;
with Landin.Driver.Checking;
with Landin.Driver.Loading;
with Landin.Modules;
with Landin.Panics;
with Landin.Platform.Overlays;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Stages.Syntax;

package body Landin.Server.Analysis is

   package Unbounded renames Ada.Strings.Unbounded;
   package Diag renames Landin.Diagnostics;
   package Rows renames Landin.Diagnostics.Catalogue;

   use type Diag.Severity;
   use type Landin.Modules.Module_Id;
   use type Landin.Source.Source_Id;
   use type Holes.Verdict;

   package Plan_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Holes.Plan, "=" => Holes."=");

   package Name_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

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
     (For_Target : Landin.Targets.Target_Facts;
      At_Level   : Landin.Targets.Levels.Feature_Level;
      Host    : Landin.Platform.Filesystem'Class;
      Asked   : Request;
      Visit   : not null access procedure
        (Context : in out Landin.Stages.Compilation; Answer : Result);
      Watch_Syntax : access procedure (Name : String) := null)
   is
      Plans    : Plan_Maps.Map;
      Original_Names : Name_Vectors.Vector;
      Original_Report : Diag.Diagnostic_List;
      Rooted : constant Boolean :=
        Unbounded.Length (Asked.Entry_Directory) > 0;
      Entry_Directory : constant String :=
        Unbounded.To_String (Asked.Entry_Directory);
      Standing : Boolean := False;
      Missing : aliased Landin.Platform.Path_List;
      procedure Apply_Options (Context : in out Landin.Stages.Compilation);

      procedure Apply_Options (Context : in out Landin.Stages.Compilation) is
      begin
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
      end Apply_Options;

      procedure Load
        (Context : in out Landin.Stages.Compilation;
         From    : Landin.Platform.Filesystem'Class;
         Previous : access Landin.Stages.Compilation := null);

      procedure Load
        (Context : in out Landin.Stages.Compilation;
         From    : Landin.Platform.Filesystem'Class;
         Previous : access Landin.Stages.Compilation := null)
      is
         Outcome  : Landin.Stages.Stage_Outcome;
      begin
         if Rooted then
            Landin.Driver.Loading.Load_Reachable_Program
              (Context, From, Asked.Roots, Entry_Directory,
               Missing'Access, Previous, Watch_Syntax);
         else
            Landin.Driver.Loading.Load_Files (Context, From, Asked.Files);
            if Landin.Stages.Source_Count (Context) > 0
              and then not Landin.Stages.Failed (Context)
            then
               Landin.Stages.Syntax.Run_Using
                 (Context, Outcome, Previous, Watch_Syntax);
            end if;
         end if;
      end Load;

      procedure Finish (Context : in out Landin.Stages.Compilation);

      procedure Finish (Context : in out Landin.Stages.Compilation) is
         Answer : Result;
         Panic  : Landin.Panics.Plan;
      begin
         if Landin.Stages.Source_Count (Context) > 0
           and then not Landin.Stages.Failed (Context)
         then
            Landin.Driver.Checking.Run (Context, Panic);
            --  Names and types exist only where every frontend stage ran,
            --  which is exactly when nothing before the checker refused.
            Answer.Checked := not Has_Frontend_Error (Context);
         end if;
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
                        for Position in 1 .. Original_Report.Count loop
                           declare
                              Item : constant Diag.Diagnostic :=
                                Original_Report.Get (Position);
                              Old_Id : constant Landin.Source.Source_Id :=
                                Diag.Source_Of (Diag.Primary (Item));
                           begin
                              if Old_Id /= Landin.Source.No_Source
                                and then Natural (Old_Id)
                                  <= Natural (Original_Names.Length)
                                and then Original_Names.Element
                                  (Natural (Old_Id)) = Name
                              then
                                 Merged.Append (Diag.Retargeted (Item, Id));
                              end if;
                           end;
                        end loop;
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
         Visit (Context, Answer);
      end Finish;

   begin
      declare
         Original : aliased Landin.Stages.Compilation :=
           Landin.Stages.Create (For_Target, At_Level);
      begin
         Apply_Options (Original);
         Load (Original, Host);
         Original_Report := Landin.Stages.Report (Original);

         --  The first syntax stage has already parsed every loaded source.
         --  Only an entry source with an error needs the more expensive body
         --  plan.  Imported sources are never stood in for.
         for Index in 1 .. Landin.Stages.Source_Count (Original) loop
            declare
               Id : constant Landin.Source.Source_Id :=
                 Landin.Stages.Nth_Source (Original, Index);
               Has_Error : Boolean := False;
            begin
               if Landin.Modules.Module_Of
                 (Landin.Stages.Modules (Original).all, Id)
                 = Landin.Modules.Entry_Module
               then
                  for Position in 1 .. Original_Report.Count loop
                     declare
                        Item : constant Diag.Diagnostic :=
                          Original_Report.Get (Position);
                     begin
                        --  The loader may also attach an import error to a
                        --  sound entry source.  Only lexical and parser
                        --  errors call for a body plan.
                        if Diag.Level (Item) = Diag.Error
                          and then Diag.Source_Of (Diag.Primary (Item)) = Id
                          and then Rows.Named (Diag.Code (Item)) in
                            Rows.Construct_Not_Enabled
                            .. Rows.Positional_After_Named
                        then
                           Has_Error := True;
                           exit;
                        end if;
                     end;
                  end loop;
                  if Has_Error then
                     declare
                        Snapshot : Landin.Source.Snapshot renames
                          Landin.Stages.Source (Original, Id).Element.all;
                     begin
                        Plans.Insert
                          (Landin.Source.Name (Snapshot),
                           Holes.Plan_For (Landin.Source.Text (Snapshot)));
                     end;
                  end if;
               end if;
            end;
         end loop;

         for Plan of Plans loop
            Standing := Standing or else Plan.Outcome = Holes.Stood_In;
            if Plan.Outcome = Holes.Refused then
               Standing := False;
               exit;
            end if;
         end loop;

         if Standing then
            --  Retarget the first pass's syntax reports after this
            --  compilation has been released.
            for Index in 1 .. Landin.Stages.Source_Count (Original) loop
               declare
                  Id : constant Landin.Source.Source_Id :=
                    Landin.Stages.Nth_Source (Original, Index);
               begin
                  Original_Names.Append
                    (Landin.Source.Name
                      (Landin.Stages.Source (Original, Id).Element.all));
               end;
            end loop;
         else
            Finish (Original);
         end if;

         if Standing then
            declare
               Stand_In : Landin.Platform.Overlays.Overlay (Host'Access);
               Context : Landin.Stages.Compilation :=
                 Landin.Stages.Create (For_Target, At_Level);
            begin
               for Position in Plans.Iterate loop
                  Stand_In.Hold
                    (Plan_Maps.Key (Position),
                     Plan_Maps.Element (Position).Text);
               end loop;
               --  Moved trees keep their original Name_Id values.  Copy
               --  the name table before the stand-in can intern new names.
               Landin.Source.Names.Copy_Into
                 (Landin.Stages.Identities (Original).all,
                  Landin.Stages.Identities (Context).all);
               Apply_Options (Context);
               Load (Context, Stand_In, Original'Access);
               Finish (Context);
            end;
         end if;
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
