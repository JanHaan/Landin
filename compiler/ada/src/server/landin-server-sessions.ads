--  One session: the protocol from `initialize` to `exit`.
--
--  What the server offers, and nothing else:
--
--  * full document synchronisation, open, change and close;
--  * diagnostics published for every source of an analysed module, with
--    the catalogue code, a link to its explanation, related information
--    from each secondary label and each note in the message;
--  * formatting, D252's layout as text edits;
--  * code actions, one quick fix per fix on a diagnostic the request's
--    range touches, preferred when its applicability is exact;
--  * definitions and hover, from the module's names and types.
--
--  A request the server does not offer is MethodNotFound, one before
--  `initialize` ServerNotInitialized, one after `shutdown`
--  InvalidRequest, and a notification it does not know is ignored.
--  Cancellation notifications are ignored: requests are answered before
--  the next message is read.  Positions are UTF-8 when the editor offers
--  it and UTF-16 otherwise.
--
--  When to analyse: after every change, but never while more input is
--  already waiting, so a burst of edits is analysed once.  A request is
--  answered from the documents as they stood when it arrived, analysing
--  first if they changed.  One compilation is alive at a time.

with Landin.Platform;

package Landin.Server.Sessions is

   --  How a session ended, which is the process's exit status: 0 after
   --  `shutdown` and `exit`, 1 for an `exit` without `shutdown`, the end
   --  of input, or framing that cannot be read.
   subtype Exit_Status is Natural range 0 .. 1;

   --  Serve one editor over Channel, reading files through Host.
   procedure Serve
     (Channel : in out Landin.Platform.Channel'Class;
      Host    : not null access constant Landin.Platform.Filesystem'Class;
      Status  : out Exit_Status);

end Landin.Server.Sessions;
