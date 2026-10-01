--  The protocol's framing: a header block, a blank line, a body.
--
--  Each header line ends in CR LF and is a name, a colon and a value.
--  Names are compared without case, a header nobody asked for is ignored,
--  and Content-Length -- decimal, required, once -- says how many bytes of
--  body follow.  A Content-Type, if there is one, must be JSON-RPC in
--  UTF-8, which is the only thing the protocol defines.
--
--  What a faulty frame costs is what it has to: a body the length is known
--  for can be skipped, so a message that is too long is read past and the
--  server goes on; a header that cannot be read leaves no way to find the
--  next message, so the connection ends.  The bounds are a header block of
--  Maximum_Header bytes and a body of Maximum_Body.

with Ada.Strings.Unbounded;

with Landin.Platform;

package Landin.Server.Transport is

   Maximum_Header : constant := 4 * 1024;
   Maximum_Body   : constant := 64 * 1024 * 1024;

   type Status is
     (Message,       --  Body holds one message
      Too_Long,      --  a body past Maximum_Body was read and dropped
      Ended,         --  the input ended between two messages
      Broken);       --  the framing cannot be read; Fault says why

   type Reader is limited private;

   --  The next message's body.  Bytes read past it are kept for the next.
   procedure Next
     (From    : in out Reader;
      Channel : in out Landin.Platform.Channel'Class;
      Outcome : out Status;
      Body_Of : out Ada.Strings.Unbounded.Unbounded_String;
      Fault   : out Ada.Strings.Unbounded.Unbounded_String);

   --  Whether a message, or the start of one, is waiting: bytes held from
   --  an earlier read, or bytes the channel has now.
   function Waiting
     (From    : Reader;
      Channel : in out Landin.Platform.Channel'Class) return Boolean;

   --  Item framed: its length header, the blank line and its bytes.
   function Framed (Item : String) return String;

private

   type Reader is limited record
      Held : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Landin.Server.Transport;
