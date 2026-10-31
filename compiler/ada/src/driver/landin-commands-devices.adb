with Ada.Strings.Unbounded;

with Landin.Devices;
with Landin.Devices.Projection;
with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Text;
with Landin.Json;
with Landin.Source;
with Landin.Source.Sets;

package body Landin.Commands.Devices is

   package US renames Ada.Strings.Unbounded;
   package Dev renames Landin.Devices;
   package Cat renames Landin.Diagnostics.Catalogue;
   package Platform renames Landin.Platform;
   package J renames Landin.Json;

   use type Platform.Read_Status;
   use type Platform.Write_Status;
   use type Platform.Move_Status;
   use type Dev.Fault_Kind;
   use type Dev.Input;
   use type J.Value_Kind;
   use type Landin.Source.Byte_Offset;

   Staged_Suffix : constant String := ".refine-new";
   Kept_Suffix : constant String := ".refine-old";

   function Code_For (Kind : Dev.Fault_Kind) return Cat.Code_Name is
     (case Kind is
         when Dev.Malformed_Svd => Cat.Svd_Malformed,
         when Dev.Invalid_Policy => Cat.Svd_Policy_Invalid,
         when Dev.Input_Mismatch => Cat.Svd_Input_Mismatch,
         when Dev.Unsupported_Form => Cat.Svd_Form_Unsupported,
         when Dev.Inconsistent_Device => Cat.Svd_Device_Inconsistent,
         when Dev.Not_In_Svd | Dev.No_Fault => Cat.Svd_Not_Found);

   procedure Import
     (Svd_Path, Policy_Path, Out_Dir : String;
      Host   : Landin.Platform.Filesystem'Class;
      Result : in out Landin.Driver.Outcome)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Svd_Text, Policy_Text : US.Unbounded_String;
      Read : Platform.Read_Status;
      Made : Dev.Projection.Result;
      Problem : Dev.Fault;
      Root : constant String :=
        (if Out_Dir'Length > 1 and then Out_Dir (Out_Dir'Last) = '/'
         then Out_Dir (Out_Dir'First .. Out_Dir'Last - 1) else Out_Dir);

      function Destination (Path : String) return String is
        (Root & "/" & Path);

      procedure Report
        (Code : Cat.Code_Name; Message : String;
         Source : Landin.Source.Source_Id := Landin.Source.No_Source;
         Where : Landin.Source.Span := Landin.Source.Empty_Span);

      procedure Report
        (Code : Cat.Code_Name; Message : String;
         Source : Landin.Source.Source_Id := Landin.Source.No_Source;
         Where : Landin.Source.Span := Landin.Source.Empty_Span) is
      begin
         Result.Status := Landin.Driver.Status_Reported;
         Result.Found.Append
           (Landin.Diagnostics.Make
              (Code => Cat.Code (Code), Level => Landin.Diagnostics.Error,
               Source => Source, Where => Where, Message => Message));
         Result.Report := US.To_Unbounded_String
           (Landin.Diagnostics.Text.Render (Result.Found, Sources));
      end Report;

      --  Every destination, and every file the old manifest names that is
      --  no longer made: what the replacement will touch.
      Stale : Platform.Path_List;

      function Preflight return Boolean;

      function Preflight return Boolean is
         Manifest_Path : constant String :=
           Destination (US.To_String (Made.Manifest));

         function Clear (Path : String) return Boolean;

         function Clear (Path : String) return Boolean is
         begin
            if Host.Is_Directory (Path) then
               Report (Cat.Svd_Output_Refused, Path & " is a directory,"
                       & " where refine svd writes a file; remove it");
               return False;
            end if;
            for Suffix of Platform.Path_List'
              [Staged_Suffix, Kept_Suffix]
            loop
               if Host.Exists (Path & Suffix) then
                  Report (Cat.Svd_Output_Refused, Path & Suffix & " was"
                          & " left by an interrupted run of refine svd;"
                          & " compare it with " & Path & ", keep the one"
                          & " you want, and remove it");
                  return False;
               end if;
            end loop;
            --  Each directory above it under the root must be one.
            for Index in Path'First + Root'Length + 1 .. Path'Last loop
               if Path (Index) = '/'
                 and then Host.Exists (Path (Path'First .. Index - 1))
                 and then not Host.Is_Directory
                   (Path (Path'First .. Index - 1))
               then
                  Report (Cat.Svd_Output_Refused,
                          Path (Path'First .. Index - 1) & " is a file,"
                          & " where refine svd needs a directory");
                  return False;
               end if;
            end loop;
            return True;
         end Clear;
      begin
         if not Host.Is_Directory (Root) then
            Report (Cat.Svd_Output_Refused, "the output directory " & Root
                    & " is not a directory; make it, or name another with"
                    & " --out-dir");
            return False;
         end if;
         for Item of Made.Outputs loop
            if not Clear (Destination (US.To_String (Item.Path))) then
               return False;
            end if;
         end loop;
         if Host.Exists (Manifest_Path) then
            declare
               Old_Text : US.Unbounded_String;
               Old : J.Document;
            begin
               Host.Read_File (Manifest_Path, Old_Text, Read);
               if Read /= Platform.Read_Ok then
                  Report (Cat.Svd_Output_Refused, "the manifest "
                          & Manifest_Path & " cannot be read, so the"
                          & " files it names cannot be replaced");
                  return False;
               end if;
               J.Parse (Old, US.To_String (Old_Text));
               if not J.Ok (Old)
                 or else J.Kind (Old, J.Root (Old)) /= J.Object_Value
               then
                  Report (Cat.Svd_Output_Refused, "the manifest "
                          & Manifest_Path & " is not a JSON object of the"
                          & " files refine svd wrote; remove it if it is"
                          & " not one");
                  return False;
               end if;
               for Position in 1 .. J.Length (Old, J.Root (Old)) loop
                  declare
                     Named : constant String :=
                       J.Key (Old, J.Root (Old), Position);
                     Whole : constant String := Dev.Projection.Under
                       (US.To_String (Made.Modules), Named);
                     Still_Made : Boolean := False;
                  begin
                     if not Dev.Is_Relative_Path (Named) then
                        Report (Cat.Svd_Output_Refused, "the manifest "
                                & Manifest_Path & " names " & Named
                                & ", which is not a path below it");
                        return False;
                     end if;
                     for Item of Made.Outputs loop
                        if US.To_String (Item.Path) = Whole then
                           Still_Made := True;
                        end if;
                     end loop;
                     if not Still_Made
                       and then Host.Exists (Destination (Whole))
                     then
                        if not Clear (Destination (Whole)) then
                           return False;
                        end if;
                        Stale.Append (Destination (Whole));
                     end if;
                  end;
               end loop;
            end;
         end if;
         return True;
      end Preflight;

      --  What each output does: nothing when its bytes are already there.
      type Plan is (Unchanged, Created, Replaced);

      type Plans is array (Positive range <>) of Plan;

      procedure Replace;

      procedure Replace is
         Steps : Plans (1 .. Made.Outputs.Last_Index) := [others => Created];
         Done : Natural := 0;
         Removed_Stale : Natural := 0;
         Written : Platform.Write_Status;
         Moved : Platform.Move_Status;
         Gone : Platform.Remove_Status;
         Failure : US.Unbounded_String;

         procedure Make_Parents (Path : String);

         procedure Make_Parents (Path : String) is
         begin
            for Index in Path'First + Root'Length + 1 .. Path'Last loop
               if Path (Index) = '/' then
                  Host.Make_Directory (Path (Path'First .. Index - 1),
                                       Written);
                  if Written /= Platform.Write_Ok then
                     Failure := US.To_Unbounded_String
                       ("cannot make the directory "
                        & Path (Path'First .. Index - 1));
                     return;
                  end if;
               end if;
            end loop;
         end Make_Parents;

         procedure Discard_Staged;

         procedure Discard_Staged is
         begin
            for Index in 1 .. Made.Outputs.Last_Index loop
               if Steps (Index) /= Unchanged then
                  Host.Remove_File
                    (Destination (US.To_String (Made.Outputs (Index).Path))
                     & Staged_Suffix, Gone);
               end if;
            end loop;
         end Discard_Staged;

         procedure Roll_Back;

         --  Put back what was replaced, newest first; say which kept copy
         --  is the old file when one cannot be put back.
         procedure Roll_Back is
            Stuck : US.Unbounded_String;
         begin
            for Index in reverse 1 .. Removed_Stale loop
               Host.Move_File (Stale (Index) & Kept_Suffix, Stale (Index),
                               Moved);
               if Moved /= Platform.Moved then
                  US.Append (Stuck, " " & Stale (Index) & Kept_Suffix);
               end if;
            end loop;
            for Index in reverse 1 .. Done loop
               declare
                  Path : constant String :=
                    Destination (US.To_String (Made.Outputs (Index).Path));
               begin
                  if Steps (Index) /= Unchanged then
                     Host.Remove_File (Path, Gone);
                  end if;
                  if Steps (Index) = Replaced then
                     Host.Move_File (Path & Kept_Suffix, Path, Moved);
                     if Moved /= Platform.Moved then
                        US.Append (Stuck, " " & Path & Kept_Suffix);
                     end if;
                  end if;
               end;
            end loop;
            Discard_Staged;
            if US.Length (Stuck) > 0 then
               US.Append (Failure, "; the old files could not all be put"
                          & " back, and are kept as"
                          & US.To_String (Stuck));
            else
               US.Append (Failure, "; every old file was put back");
            end if;
         end Roll_Back;
      begin
         --  Stage and verify every new file before replacing any.
         for Index in 1 .. Made.Outputs.Last_Index loop
            declare
               Item : constant Dev.Output := Made.Outputs (Index);
               Path : constant String :=
                 Destination (US.To_String (Item.Path));
               Existing : US.Unbounded_String;
            begin
               if Host.Exists (Path) then
                  Host.Read_File (Path, Existing, Read);
                  Steps (Index) :=
                    (if Read = Platform.Read_Ok
                       and then US."=" (Existing, Item.Content)
                     then Unchanged else Replaced);
               end if;
               if Steps (Index) /= Unchanged then
                  Make_Parents (Path);
                  if US.Length (Failure) = 0 then
                     Host.Write_File (Path & Staged_Suffix,
                                      US.To_String (Item.Content), Written);
                     Host.Read_File (Path & Staged_Suffix, Existing, Read);
                     if Written /= Platform.Write_Ok
                       or else Read /= Platform.Read_Ok
                       or else not US."=" (Existing, Item.Content)
                     then
                        Failure := US.To_Unbounded_String
                          ("cannot write and read back " & Path
                           & Staged_Suffix);
                     end if;
                  end if;
               end if;
               if US.Length (Failure) > 0 then
                  Discard_Staged;
                  Report (Cat.Unwritable_Output, US.To_String (Failure)
                          & "; nothing was replaced");
                  return;
               end if;
            end;
         end loop;
         for Index in 1 .. Made.Outputs.Last_Index loop
            declare
               Path : constant String :=
                 Destination (US.To_String (Made.Outputs (Index).Path));
            begin
               if Steps (Index) = Replaced then
                  Host.Move_File (Path, Path & Kept_Suffix, Moved);
                  if Moved /= Platform.Moved then
                     Failure := US.To_Unbounded_String
                       ("cannot move " & Path & " aside to replace it");
                  end if;
               end if;
               if US.Length (Failure) = 0 and then Steps (Index) /= Unchanged
               then
                  Host.Move_File (Path & Staged_Suffix, Path, Moved);
                  if Moved /= Platform.Moved then
                     Failure := US.To_Unbounded_String
                       ("cannot move the new " & Path & " into place");
                     if Steps (Index) = Replaced then
                        Host.Move_File (Path & Kept_Suffix, Path, Moved);
                     end if;
                  end if;
               end if;
               if US.Length (Failure) > 0 then
                  Roll_Back;
                  Report (Cat.Unwritable_Output, US.To_String (Failure));
                  return;
               end if;
               Done := Index;
            end;
         end loop;
         for Path of Stale loop
            Host.Move_File (Path, Path & Kept_Suffix, Moved);
            if Moved /= Platform.Moved then
               Failure := US.To_Unbounded_String
                 ("cannot remove " & Path & ", which the old manifest names"
                  & " and this run does not make");
               Roll_Back;
               Report (Cat.Unwritable_Output, US.To_String (Failure));
               return;
            end if;
            Removed_Stale := Removed_Stale + 1;
         end loop;
         --  Every new file is in place: the kept copies go.
         for Index in 1 .. Made.Outputs.Last_Index loop
            if Steps (Index) = Replaced then
               Host.Remove_File
                 (Destination (US.To_String (Made.Outputs (Index).Path))
                  & Kept_Suffix, Gone);
            end if;
         end loop;
         for Path of Stale loop
            Host.Remove_File (Path & Kept_Suffix, Gone);
         end loop;
         declare
            Changed : Natural := 0;
         begin
            for Step of Steps loop
               if Step /= Unchanged then
                  Changed := Changed + 1;
               end if;
            end loop;
            Result.Output := US.To_Unbounded_String
              ("refine svd: " & Dev.Decimal (Dev.Word (Made.Outputs.Length))
               & " files under " & Root & ", "
               & Dev.Decimal (Dev.Word (Changed)) & " of them written"
               & (if Stale.Is_Empty then ""
                  else ", and " & Dev.Decimal (Dev.Word (Stale.Length))
                    & " no longer made removed")
               & ASCII.LF);
         end;
      end Replace;

   begin
      Host.Read_File (Svd_Path, Svd_Text, Read);
      if Read /= Platform.Read_Ok then
         Report (Cat.Unreadable_Source, "cannot read the SVD " & Svd_Path
                 & (if Read = Platform.Not_Found then ": it does not exist"
                    else ""));
         return;
      end if;
      Host.Read_File (Policy_Path, Policy_Text, Read);
      if Read /= Platform.Read_Ok then
         Report (Cat.Unreadable_Source, "cannot read the policy "
                 & Policy_Path
                 & (if Read = Platform.Not_Found then ": it does not exist"
                    else ""));
         return;
      end if;
      declare
         Svd_Id : constant Landin.Source.Source_Id :=
           Sources.Add (Svd_Path, US.To_String (Svd_Text));
         Policy_Id : constant Landin.Source.Source_Id :=
           Sources.Add (Policy_Path, US.To_String (Policy_Text));
      begin
         Result.Named.Append (Svd_Path);
         Result.Named.Append (Policy_Path);
         Dev.Projection.Project
           (US.To_String (Svd_Text), US.To_String (Policy_Text), Made,
            Problem);
         if Problem.Kind /= Dev.No_Fault then
            declare
               Length : constant Natural :=
                 (if Problem.Within = Dev.Svd_Input
                  then US.Length (Svd_Text) else US.Length (Policy_Text));
               First : constant Landin.Source.Byte_Offset :=
                 Landin.Source.Byte_Offset
                   (Natural'Min (Problem.Offset, Length));
            begin
               Report (Code_For (Problem.Kind),
                       US.To_String (Problem.Message),
                       (if Problem.Within = Dev.Svd_Input then Svd_Id
                        else Policy_Id),
                       (First => First,
                        Last => (if Problem.Has_Offset
                                   and then Natural (First) < Length
                                 then First + 1 else First)));
            end;
            return;
         end if;
      end;
      if Preflight then
         Replace;
      end if;
   end Import;

end Landin.Commands.Devices;
