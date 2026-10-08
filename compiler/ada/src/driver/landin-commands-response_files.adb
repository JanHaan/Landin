package body Landin.Commands.Response_Files is
   package US renames Ada.Strings.Unbounded;
   use type Landin.Platform.Read_Status;

   procedure Expand
     (Arguments : Landin.Platform.Path_List;
      Host : Landin.Platform.Filesystem'Class;
      Result : out Landin.Platform.Path_List;
      Problem : out US.Unbounded_String)
   is
      Active : Landin.Platform.Path_List;
      Literal : Boolean := False;
      Total_Bytes : Natural := 0;
      procedure Add (Argument : String; Depth : Natural);

      procedure Add (Argument : String; Depth : Natural) is
         Content : US.Unbounded_String;
         Status : Landin.Platform.Read_Status;
      begin
         if US.Length (Problem) > 0 then
            return;
         elsif Natural (Result.Length) >= 8192 then
            Problem := US.To_Unbounded_String
              ("response expansion exceeds 8192 arguments");
         elsif Argument = "--" then
            Literal := True;
            Result.Append (Argument);
         elsif Literal or else Argument'Length = 0
           or else Argument (Argument'First) /= '@'
         then
            Result.Append (Argument);
         elsif Argument'Length = 1 or else Depth >= 8 then
            Problem := US.To_Unbounded_String
              ("response files need a path and at most eight nesting levels");
         else
            declare
               Path : constant String :=
                 Argument (Argument'First + 1 .. Argument'Last);
            begin
               for Earlier of Active loop
                  if Path = Earlier or else Host.Same_File (Path, Earlier) then
                     Problem := US.To_Unbounded_String
                       ("response file cycle: " & Path);
                     return;
                  end if;
               end loop;
               Host.Read_File (Path, Content, Status);
               if Status /= Landin.Platform.Read_Ok then
                  Problem := US.To_Unbounded_String
                    ("cannot read response file: " & Path);
                  return;
               elsif US.Length (Content) > 1_048_576 - Total_Bytes then
                  Problem := US.To_Unbounded_String
                    ("response expansion exceeds 1 MiB");
                  return;
               end if;
               Total_Bytes := Total_Bytes + US.Length (Content);
               Active.Append (Path);
               declare
                  Bytes : constant String := US.To_String (Content);
                  Token : US.Unbounded_String;
                  Quote : Character := ASCII.NUL;
                  Escaped, Started, Comment : Boolean := False;
                  procedure Flush;
                  procedure Flush is
                  begin
                     if Started then
                        Add (US.To_String (Token), Depth + 1);
                        Token := US.Null_Unbounded_String;
                        Started := False;
                     end if;
                  end Flush;
               begin
                  for Byte of Bytes loop
                     if Comment then
                        Comment := Byte not in ASCII.LF | ASCII.CR;
                     elsif Escaped then
                        US.Append (Token, Byte);
                        Escaped := False;
                     elsif Byte = '\' and then Quote /= ''' then
                        Escaped := True;
                        Started := True;
                     elsif Quote /= ASCII.NUL then
                        if Byte = Quote then
                           Quote := ASCII.NUL;
                        else
                           US.Append (Token, Byte);
                        end if;
                     elsif Byte in ''' | '"' then
                        Quote := Byte;
                        Started := True;
                     elsif Byte = '#' and then not Started then
                        Comment := True;
                     elsif Byte in ' ' | ASCII.HT | ASCII.LF | ASCII.CR then
                        Flush;
                     else
                        Started := True;
                        US.Append (Token, Byte);
                     end if;
                     exit when US.Length (Problem) > 0;
                  end loop;
                  if Quote /= ASCII.NUL or else Escaped then
                     Problem := US.To_Unbounded_String
                       ("unterminated quote or escape in response file: "
                        & Path);
                  else
                     Flush;
                  end if;
               end;
               Active.Delete_Last;
            end;
         end if;
      end Add;
   begin
      Result.Clear;
      Problem := US.Null_Unbounded_String;
      for Argument of Arguments loop
         Add (Argument, 0);
         exit when US.Length (Problem) > 0;
      end loop;
   end Expand;
end Landin.Commands.Response_Files;
