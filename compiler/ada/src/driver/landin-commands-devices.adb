with Ada.Strings.Unbounded;

with Landin.Devices;
with Landin.Devices.Projection;
with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Text;
with Landin.Json;
with Landin.Platform.Publication;
with Landin.Source;
with Landin.Source.Sets;

package body Landin.Commands.Devices is

   package US renames Ada.Strings.Unbounded;
   package Dev renames Landin.Devices;
   package Cat renames Landin.Diagnostics.Catalogue;
   package Platform renames Landin.Platform;
   package Pub renames Landin.Platform.Publication;
   package J renames Landin.Json;

   use type Platform.Read_Status;
   use type Platform.Write_Status;
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

   function Output_Root (Path : String) return String;

   function Output_Root (Path : String) return String is
      Last : Natural := Path'Last;
   begin
      while Last > Path'First and then Path (Last) = '/' loop
         Last := Last - 1;
      end loop;
      return Path (Path'First .. Last);
   end Output_Root;

   procedure Import
     (Svd_Path, Policy_Path, Out_Dir : String;
      Host   : Landin.Platform.Filesystem'Class;
      Result : in out Landin.Driver.Outcome;
      Protected_Inputs : Landin.Platform.Path_List :=
        Landin.Platform.Path_Vectors.Empty_Vector;
      Protected_Identities : Landin.Platform.Identity_List :=
        Landin.Platform.Identity_Vectors.Empty_Vector)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Svd_Text, Policy_Text : US.Unbounded_String;
      Read : Platform.Read_Status;
      Made : Dev.Projection.Result;
      Problem : Dev.Fault;
      Group : Pub.Transaction;
      Has_Group : Boolean := False;
      Inputs : Platform.Path_List := Protected_Inputs;
      Svd_Identity, Policy_Identity : Platform.File_Identity;
      Root : constant String := Output_Root (Out_Dir);

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
            if Host.Exists (Path)
              and then Host.Paths_Overlap_Any (Path, Inputs)
            then
               declare
                  Short : constant String :=
                    Host.Separation_Shortage (Path, Inputs);
               begin
                  Report (Cat.Svd_Output_Refused,
                          (if Short /= ""
                           then Path & " could not be compared with the"
                             & " inputs: " & Short
                             & "; retry when the host can spare more"
                           else Path & " overlaps an input; name another"
                             & " output directory with --out-dir"));
               end;
               return False;
            end if;
            if Host.Is_Link (Path) then
               Report (Cat.Svd_Output_Refused, Path & " is a symbolic link;"
                       & " remove it or name another output directory");
               return False;
            end if;
            if Host.Is_Directory (Path) then
               Report (Cat.Svd_Output_Refused, Path & " is a directory,"
                       & " where refine svd writes a file; remove it");
               return False;
            end if;
            for Suffix of Platform.Path_List'
              [Staged_Suffix, Kept_Suffix]
            loop
               if Host.Exists (Path & Suffix)
                 or else Host.Is_Link (Path & Suffix)
               then
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
                 and then Host.Is_Link (Path (Path'First .. Index - 1))
               then
                  Report (Cat.Svd_Output_Refused,
                          Path (Path'First .. Index - 1)
                          & " is a symbolic link below the output directory;"
                          & " remove it or name another output directory");
                  return False;
               end if;
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
         if Host.Is_Link (Root) then
            Report (Cat.Svd_Output_Refused, "the output directory " & Root
                    & " is a symbolic link; name the directory it leads to"
                    & " with --out-dir");
            return False;
         end if;
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
         Has_Group := True;
         for Item of Made.Outputs loop
            declare
               Status : Platform.Write_Status;
               Reason : US.Unbounded_String;
            begin
               Pub.Prepare
                 (Group, Host, Destination (US.To_String (Item.Path)),
                  Status, Reason, Root => Root);
               if Status /= Platform.Write_Ok then
                  Report (Cat.Svd_Output_Refused, US.To_String (Reason));
                  return False;
               end if;
            end;
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
                       and then (Host.Exists (Destination (Whole))
                                 or else Host.Is_Link (Destination (Whole)))
                     then
                        if not Clear (Destination (Whole)) then
                           return False;
                        end if;
                        --  The manifest's names alone do not decide what
                        --  is removed: a file goes only while it is still
                        --  the bytes the manifest says refine svd wrote.
                        declare
                           Recorded : constant J.Value :=
                             J.Member_Value (Old, J.Root (Old), Position);
                           Kept : US.Unbounded_String;
                        begin
                           Host.Read_File (Destination (Whole), Kept, Read);
                           if Read /= Platform.Read_Ok
                             or else not J.Is_Kind
                               (Old, Recorded, J.String_Value)
                             or else Dev.Projection.Sha256
                               (US.To_String (Kept))
                               /= J.Text (Old, Recorded)
                           then
                              Report (Cat.Svd_Output_Refused, "the manifest "
                                      & Manifest_Path & " names "
                                      & Destination (Whole) & ", which this"
                                      & " run no longer makes and would"
                                      & " remove, but it is not the file"
                                      & " the manifest says refine svd"
                                      & " wrote: its SHA-256 differs or"
                                      & " cannot be taken; remove the file,"
                                      & " or its entry in the manifest to"
                                      & " keep it");
                              return False;
                           end if;
                        end;
                        declare
                           Status : Platform.Write_Status;
                           Reason : US.Unbounded_String;
                        begin
                           Pub.Prepare
                             (Group, Host, Destination (Whole), Status,
                              Reason, Delete_Only => True, Root => Root);
                           if Status /= Platform.Write_Ok then
                              Report (Cat.Svd_Output_Refused,
                                      US.To_String (Reason));
                              return False;
                           end if;
                        end;
                        Stale.Append (Destination (Whole));
                     end if;
                  end;
               end loop;
            end;
         end if;
         return True;
      end Preflight;

      procedure Clean_Up;

      procedure Clean_Up is
         Status : Platform.Write_Status;
         Reason : US.Unbounded_String;
      begin
         if Has_Group then
            Pub.Abort_Transaction (Group, Host, Status, Reason);
            Has_Group := False;
            if Status /= Platform.Write_Ok then
               Report (Cat.Unwritable_Output, US.To_String (Reason));
            end if;
         end if;
      end Clean_Up;

      procedure Replace;

      procedure Replace is
         Status : Platform.Write_Status;
         Reason, Existing : US.Unbounded_String;
         Changed : Natural := 0;
      begin
         --  Every generated and stale path was prepared before staging.
         for Item of Made.Outputs loop
            declare
               Path : constant String :=
                 Destination (US.To_String (Item.Path));
            begin
               Host.Read_File (Path, Existing, Read);
               if Read /= Platform.Read_Ok
                 or else not US."=" (Existing, Item.Content)
               then
                  Changed := Changed + 1;
               end if;
               Host.Write_File (Pub.Stage_Path (Group, Path),
                                US.To_String (Item.Content), Status);
               if Status /= Platform.Write_Ok then
                  Report (Cat.Unwritable_Output,
                          "cannot write " & Pub.Stage_Path (Group, Path)
                          & "; nothing was replaced");
                  return;
               end if;
               Host.Read_File (Pub.Stage_Path (Group, Path), Existing, Read);
               if Read /= Platform.Read_Ok
                 or else not US."=" (Existing, Item.Content)
               then
                  Report (Cat.Unwritable_Output,
                          "cannot read back " & Pub.Stage_Path (Group, Path)
                          & "; nothing was replaced");
                  return;
               end if;
            end;
         end loop;
         Pub.Commit (Group, Host, Status, Reason);
         if Status /= Platform.Write_Ok then
            Report (Cat.Unwritable_Output, US.To_String (Reason));
            return;
         end if;
         Pub.Finish (Group, Host, Status, Reason);
         Has_Group := False;
         if Status /= Platform.Write_Ok then
            Report (Cat.Unwritable_Output, US.To_String (Reason));
            return;
         end if;
         Result.Output := US.To_Unbounded_String
           ("refine svd: " & Dev.Decimal (Dev.Word (Made.Outputs.Length))
            & " files under " & Root & ", "
            & Dev.Decimal (Dev.Word (Changed)) & " of them written"
            & (if Stale.Is_Empty then ""
               else ", and " & Dev.Decimal (Dev.Word (Stale.Length))
                 & " no longer made removed")
            & ASCII.LF);
      end Replace;

   begin
      for Path of Protected_Inputs loop
         Pub.Protect (Group, Host, Path);
      end loop;
      for Identity of Protected_Identities loop
         Pub.Protect (Group, "", Identity);
      end loop;
      Host.Read_Snapshot (Svd_Path, Svd_Text, Svd_Identity, Read);
      if Read /= Platform.Read_Ok then
         Report (Cat.Unreadable_Source, "cannot read the SVD " & Svd_Path
                 & (if Read = Platform.Not_Found then ": it does not exist"
                    else ""));
         return;
      end if;
      Pub.Protect (Group, Svd_Path, Svd_Identity);
      Inputs.Append (Svd_Path);
      Host.Read_Snapshot (Policy_Path, Policy_Text, Policy_Identity, Read);
      if Read /= Platform.Read_Ok then
         Report (Cat.Unreadable_Source, "cannot read the policy "
                 & Policy_Path
                 & (if Read = Platform.Not_Found then ": it does not exist"
                    else ""));
         return;
      end if;
      Pub.Protect (Group, Policy_Path, Policy_Identity);
      Inputs.Append (Policy_Path);
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
      Clean_Up;
   exception
      when others =>
         Clean_Up;
         raise;
   end Import;

end Landin.Commands.Devices;
