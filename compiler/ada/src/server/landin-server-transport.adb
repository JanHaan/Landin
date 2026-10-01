with Ada.Characters.Handling;
with Ada.Strings.Fixed;

package body Landin.Server.Transport is

   package Unbounded renames Ada.Strings.Unbounded;

   CR_LF : constant String := ASCII.CR & ASCII.LF;

   Chunk : constant := 64 * 1024;

   --  Read once more into Held.  False when the input has ended.
   function Fill
     (From    : in out Reader;
      Channel : in out Landin.Platform.Channel'Class) return Boolean;

   function Fill
     (From    : in out Reader;
      Channel : in out Landin.Platform.Channel'Class) return Boolean
   is
      Buffer : String (1 .. Chunk);
      Last   : Natural;
   begin
      Channel.Read (Buffer, Last);
      if Last < Buffer'First then
         return False;
      end if;
      Unbounded.Append (From.Held, Buffer (Buffer'First .. Last));
      return True;
   end Fill;

   function Trimmed (Text : String) return String
     is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   procedure Next
     (From    : in out Reader;
      Channel : in out Landin.Platform.Channel'Class;
      Outcome : out Status;
      Body_Of : out Ada.Strings.Unbounded.Unbounded_String;
      Fault   : out Ada.Strings.Unbounded.Unbounded_String)
   is
      Header_End : Natural;
      Length     : Natural := 0;
      Seen       : Boolean := False;

      procedure Break (Reason : String);

      procedure Break (Reason : String) is
      begin
         Outcome := Broken;
         Fault := Unbounded.To_Unbounded_String (Reason);
      end Break;
   begin
      Body_Of := Unbounded.Null_Unbounded_String;
      Fault := Unbounded.Null_Unbounded_String;

      --  The header block, up to its blank line.
      loop
         Header_End := Unbounded.Index (From.Held, CR_LF & CR_LF);
         exit when Header_End > 0;
         if Unbounded.Length (From.Held) > Maximum_Header then
            Break ("a header block is longer than"
                   & Natural'Image (Maximum_Header) & " bytes");
            return;
         end if;
         if not Fill (From, Channel) then
            if Unbounded.Length (From.Held) = 0 then
               Outcome := Ended;
            else
               Break ("the input ended inside a header");
            end if;
            return;
         end if;
      end loop;
      if Header_End - 1 > Maximum_Header then
         Break ("a header block is longer than"
                & Natural'Image (Maximum_Header) & " bytes");
         return;
      end if;

      declare
         Headers : constant String :=
           Unbounded.Slice (From.Held, 1, Header_End - 1) & CR_LF;
         Start   : Positive := Headers'First;
      begin
         Unbounded.Delete (From.Held, 1, Header_End + 3);
         while Start <= Headers'Last loop
            declare
               Stop  : constant Natural :=
                 Ada.Strings.Fixed.Index (Headers (Start .. Headers'Last),
                                          CR_LF);
               Line  : constant String := Headers (Start .. Stop - 1);
               Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ":");
            begin
               Start := Stop + 2;
               if Colon = 0 then
                  Break ("a header line has no ':'");
                  return;
               end if;
               declare
                  Name  : constant String :=
                    Ada.Characters.Handling.To_Lower
                      (Trimmed (Line (Line'First .. Colon - 1)));
                  Value : constant String :=
                    Trimmed (Line (Colon + 1 .. Line'Last));
               begin
                  if Name = "content-length" then
                     if Seen then
                        Break ("Content-Length is given twice");
                        return;
                     elsif Value'Length = 0 or else Value'Length > 10
                       or else (for some C of Value => C not in '0' .. '9')
                     then
                        Break ("Content-Length is not a decimal length");
                        return;
                     end if;
                     declare
                        Wide : constant Long_Long_Integer :=
                          Long_Long_Integer'Value (Value);
                     begin
                        if Wide > Long_Long_Integer (Natural'Last) then
                           Break ("Content-Length is not a decimal length");
                           return;
                        end if;
                        Length := Natural (Wide);
                     end;
                     Seen := True;
                  elsif Name = "content-type" then
                     declare
                        Lower : constant String :=
                          Ada.Characters.Handling.To_Lower (Value);
                     begin
                        if Ada.Strings.Fixed.Index
                             (Lower, "application/vscode-jsonrpc") /= 1
                          or else
                            (Ada.Strings.Fixed.Index (Lower, "charset") > 0
                             and then Ada.Strings.Fixed.Index
                               (Lower, "utf-8") = 0
                             and then Ada.Strings.Fixed.Index
                               (Lower, "utf8") = 0)
                        then
                           Break ("Content-Type is not JSON-RPC in UTF-8");
                           return;
                        end if;
                     end;
                  end if;
               end;
            end;
         end loop;
      end;
      if not Seen then
         Break ("a message has no Content-Length");
         return;
      end if;

      --  The body.  One too long is read past in chunks, never held.
      if Length > Maximum_Body then
         declare
            Left : Natural := Length;
         begin
            loop
               declare
                  Taken : constant Natural :=
                    Natural'Min (Left, Unbounded.Length (From.Held));
               begin
                  Unbounded.Delete (From.Held, 1, Taken);
                  Left := Left - Taken;
               end;
               exit when Left = 0;
               if not Fill (From, Channel) then
                  Break ("the input ended inside a message");
                  return;
               end if;
            end loop;
         end;
         Outcome := Too_Long;
         return;
      end if;
      while Unbounded.Length (From.Held) < Length loop
         if not Fill (From, Channel) then
            Break ("the input ended inside a message");
            return;
         end if;
      end loop;
      Body_Of := Unbounded.To_Unbounded_String
        (Unbounded.Slice (From.Held, 1, Length));
      Unbounded.Delete (From.Held, 1, Length);
      Outcome := Message;
   end Next;

   function Waiting
     (From    : Reader;
      Channel : in out Landin.Platform.Channel'Class) return Boolean
     is (Unbounded.Length (From.Held) > 0 or else Channel.Pending);

   function Framed (Item : String) return String is
      Image : constant String := Natural'Image (Item'Length);
   begin
      return "Content-Length: " & Image (Image'First + 1 .. Image'Last)
        & CR_LF & CR_LF & Item;
   end Framed;

end Landin.Server.Transport;
