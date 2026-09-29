package body Landin.Serials is

   protected Counter is
      procedure Take (Fresh : out Serial);
   private
      Last : Serial := No_Serial;
   end Counter;

   protected body Counter is
      procedure Take (Fresh : out Serial) is
      begin
         --  2 ** 64 serials outlast any process; wrapping to No_Serial
         --  would make a table's identity match nothing, not something.
         Last := Last + 1;
         Fresh := Last;
      end Take;
   end Counter;

   function Next return Serial is
      Fresh : Serial;
   begin
      Counter.Take (Fresh);
      return Fresh;
   end Next;

end Landin.Serials;
