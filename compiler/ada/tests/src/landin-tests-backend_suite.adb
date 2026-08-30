--  The frame a routine gets, and the assembly emitted against it.
--
--  These cases read the text, because the text is what an assembler is
--  handed and R1.80's exit evidence asks for it to be deterministic.  The
--  first case asserts a whole program's assembly rather than a substring
--  of it: what is being pinned is every instruction and its order, and a
--  containment check would pass on a prologue that had lost its frame
--  pointer.  That the assembly is also *correct* is what running it on
--  Linux x86-64 says, and this suite does not claim to say it.
--
--  The frame cases are separate from the emission ones on purpose.  A
--  cell's offset is target arithmetic and `Landin.Backend` computes it
--  without naming a machine, so a 32-bit description must lay out the
--  same item differently on this 64-bit host; that is the rule
--  `compiler/ada/README.md` states, checked here rather than assumed.

with Ada.Strings.Fixed;

with Landin.Backend;
with Landin.Backend.X86_64;
with Landin.IR;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.Backend_Suite is

   package IR renames Landin.IR;

   function Contains (Text : String; Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   function Index (Text : String; Needle : String) return Natural is
     (Ada.Strings.Fixed.Index (Text, Needle));

   --  How many times a needle occurs, which is how a case says a section
   --  directive was written once rather than once per object in it.
   function Occurrences (Text : String; Needle : String) return Natural;

   function Occurrences (Text : String; Needle : String) return Natural is
      Seen : Natural := 0;
      From : Positive := Text'First;
   begin
      loop
         declare
            At_Next : constant Natural :=
              Ada.Strings.Fixed.Index (Text (From .. Text'Last), Needle);
         begin
            exit when At_Next = 0;
            Seen := Seen + 1;
            exit when At_Next + Needle'Length > Text'Last;
            From := At_Next + Needle'Length;
         end;
      end loop;

      return Seen;
   end Occurrences;

   use type Landin.Source.Source_Id;
   use type Landin.Targets.Byte_Alignment;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Scalar_Size;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Checker  : aliased Landin.Stages.Checking.Instance;
   Lowerer  : aliased Landin.Stages.Lowering.Instance;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   procedure Lower
     (Work : in out Landin.Stages.Compilation;
      Text : String;
      Ran  : out Natural);

   procedure Lower
     (Work : in out Landin.Stages.Compilation;
      Text : String;
      Ran  : out Natural)
   is
      Order   : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "back.ldn", Text);
   begin
      pragma Assert (Written /= Landin.Source.No_Source);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      Ran := Landin.Stages.Run (Order, Work);
   end Lower;

   function Emitted (Work : in out Landin.Stages.Compilation) return String
     is (Landin.Backend.X86_64.Text
           (Landin.Stages.Code (Work).all,
            Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all,
            Landin.Stages.Target (Work)));

   ------------------------------------------------------------------
   --  Emission
   ------------------------------------------------------------------

   --  [1970]'s entry shape, and the whole of what it emits.  Every value
   --  is stored to its own cell and reloaded, which is the baseline
   --  `Landin.Backend`'s header states the cost of rather than hides.
   procedure A_Constant_Return_Emits_Its_Whole_Frame
     (Item : in out Landin.Testing.Context);

   procedure A_Constant_Return_Emits_Its_Whole_Frame
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;

      Expected : constant String :=
        HT & ".text" & LF
        & HT & ".globl main" & LF
        & HT & ".type main, @function" & LF
        & "main:" & LF
        & HT & "pushq %rbp" & LF
        & HT & "movq %rsp, %rbp" & LF
        & HT & "subq $16, %rsp" & LF
        & ".L1_1:" & LF
        & HT & "movabsq $42, %rax" & LF
        & HT & "movl %eax, -8(%rbp)" & LF
        & HT & "movl -8(%rbp), %eax" & LF
        & HT & "movl %eax, -4(%rbp)" & LF
        & HT & "movl -4(%rbp), %eax" & LF
        & HT & "movl %eax, -12(%rbp)" & LF
        & HT & "movl -12(%rbp), %eax" & LF
        & HT & "movq %rbp, %rsp" & LF
        & HT & "popq %rbp" & LF
        & HT & "ret" & LF
        & HT & ".size main, .-main" & LF
        & HT & ".section .note.GNU-stack,"""",@progbits" & LF;
   begin
      Lower
        (Work,
         "public main: () -> (code: i32) =" & LF
         & "    code = 42" & LF
         & "end main" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");
      Landin.Testing.Check_Equal
        (Item, Emitted (Work), Expected,
         "the entry emits its frame, its value cells and its return");
   end A_Constant_Return_Emits_Its_Whole_Frame;

   --  [1740]'s `public` is what puts a symbol in the object's table, and
   --  a function without it is emitted and not exported.
   procedure Only_A_Public_Routine_Is_Made_Global
     (Item : in out Landin.Testing.Context);

   procedure Only_A_Public_Routine_Is_Made_Global
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: () -> (r: u32) =" & LF & "    r = 1" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & ".type f, @function"),
            "the routine is emitted");
         Landin.Testing.Check
           (Item, not Contains (Text, ".globl"),
            "nothing declared it public, so nothing is global");
      end;
   end Only_A_Public_Routine_Is_Made_Global;

   --  [1650]'s C ABI hands the first integer arguments in registers, and
   --  a parameter is a slot the caller filled, so the prologue is where
   --  the register becomes a cell.
   procedure A_Parameter_Is_Stored_From_Its_Register
     (Item : in out Landin.Testing.Context);

   procedure A_Parameter_Is_Stored_From_Its_Register
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u32, b: u64) -> (r: u32) =" & LF
         & "    r = a" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "movl %edi, -4(%rbp)"),
            "the first parameter arrives in the first register, u32 wide");
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "movq %rsi, -16(%rbp)"),
            "the second arrives in the second register, u64 wide");
      end;
   end A_Parameter_Is_Stored_From_Its_Register;

   --  Every block gets a label, and a Branch spells both of its edges:
   --  the taken one as a condition and the other as a jump, so no block
   --  falls through to whichever one the emitter happened to print next.
   procedure A_Branch_Names_Both_Of_Its_Edges
     (Item : in out Landin.Testing.Context);

   procedure A_Branch_Names_Both_Of_Its_Edges
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (c: bool) -> (r: u32) =" & LF
         & "    if c then" & LF
         & "        r = 1" & LF
         & "    else" & LF
         & "        r = 2" & LF
         & "    end if" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "cmpb $0, "),
            "a bool is tested as the one byte it occupies");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jne .L1_2"),
            "the taken edge is the branch's target");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jmp .L1_3"),
            "the other edge is spelt and not fallen through to");
         Landin.Testing.Check
           (Item, Contains (Text, ".L1_5:"),
            "every block carries a label");
      end;
   end A_Branch_Names_Both_Of_Its_Edges;

   --  [0300] makes ordinary unsigned addition trap when its mathematical
   --  result does not fit.  Carry is that condition on x86-64, and the
   --  successful edge is the only one that stores the result.
   procedure Unsigned_Add_Uses_Carry_To_Trap
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_Add_Uses_Carry_To_Trap
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u8, b: u8) -> (r: u8) =" & LF
         & "    r = a + b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "addb "),
            "u8 addition uses a byte instruction");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jnc .L1_V"),
            "no carry reaches the successful continuation");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "ud2" & LF & ".L1_V"),
            "carry reaches an explicit trap before the result is stored");
      end;
   end Unsigned_Add_Uses_Carry_To_Trap;

   --  x86-64 reports an unsigned subtraction's borrow in the same carry
   --  flag, so underflow takes the trap edge ordinary `-` requires.
   procedure Unsigned_Subtract_Uses_Borrow_To_Trap
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_Subtract_Uses_Borrow_To_Trap
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u16, b: u16) -> (r: u16) =" & LF
         & "    r = a - b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "subw "),
            "u16 subtraction uses a word instruction");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jnc .L1_V"),
            "no borrow reaches the successful continuation");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "ud2" & LF & ".L1_V"),
            "borrow reaches an explicit trap before the result is stored");
      end;
   end Unsigned_Subtract_Uses_Borrow_To_Trap;

   --  Carry does not say whether a signed result is representable.  Signed
   --  arithmetic therefore takes its trap edge from x86-64's overflow flag.
   procedure Signed_Add_Uses_Overflow_To_Trap
     (Item : in out Landin.Testing.Context);

   procedure Signed_Add_Uses_Overflow_To_Trap
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i32, b: i32) -> (r: i32) =" & LF
         & "    r = a + b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "addl "),
            "i32 addition uses a long instruction");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jno .L1_V"),
            "no signed overflow reaches the successful continuation");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "jnc .L1_V"),
            "signed addition does not use unsigned carry");
      end;
   end Signed_Add_Uses_Overflow_To_Trap;

   --  isize obtains its width from the target description, while signed
   --  subtraction still uses overflow rather than borrow to decide its edge.
   procedure Signed_Subtract_Follows_The_Target_Width
     (Item : in out Landin.Testing.Context);

   procedure Signed_Subtract_Follows_The_Target_Width
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: isize, b: isize) -> (r: isize) =" & LF
         & "    r = a - b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "subq "),
            "isize subtraction follows the target's 64-bit width");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jno .L1_V"),
            "signed subtraction tests the overflow flag");
      end;
   end Signed_Subtract_Follows_The_Target_Width;

   --  [0330]'s `~` gives its own integer type back and cannot overflow, so
   --  it is one width-specific `not` through the accumulator with no edge.
   procedure Complement_Inverts_Without_A_Trap
     (Item : in out Landin.Testing.Context);

   procedure Complement_Inverts_Without_A_Trap
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u8) -> (r: u8) =" & LF
         & "    r = ~a" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movb -3(%rbp), %al" & LF
           & HT & "notb %al" & LF
           & HT & "movb %al, -4(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "u8 complement inverts through the accumulator");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "ud2"),
            "complement has no trap edge");
      end;
   end Complement_Inverts_Without_A_Trap;

   --  Unary minus gives its own integer type back [1890], so negating the
   --  lowest signed value overflows exactly as [0300] describes.  `neg` sets
   --  overflow for precisely that operand, which is the edge to test.
   procedure Signed_Negation_Traps_On_The_Lowest_Value
     (Item : in out Landin.Testing.Context);

   procedure Signed_Negation_Traps_On_The_Lowest_Value
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i8) -> (r: i8) =" & LF
         & "    r = -a" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movb -3(%rbp), %al" & LF
           & HT & "negb %al" & LF
           & HT & "jno .L1_V2" & LF
           & HT & "ud2" & LF
           & ".L1_V2:" & LF
           & HT & "movb %al, -4(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "i8 negation traps before storing an unrepresentable result");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "jnc .L1_V2"),
            "signed negation does not use unsigned carry");
      end;
   end Signed_Negation_Traps_On_The_Lowest_Value;

   --  An unsigned type holds the negation of zero and of nothing else, and
   --  `neg` sets carry for exactly the operands that are not zero.
   procedure Unsigned_Negation_Uses_Carry_To_Trap
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_Negation_Uses_Carry_To_Trap
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: usize) -> (r: usize) =" & LF
         & "    r = -a" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "negq %rax"),
            "usize negation follows the target's 64-bit width");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jnc .L1_V2"),
            "unsigned negation tests carry");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "jno .L1_V2"),
            "unsigned negation does not use signed overflow");
      end;
   end Unsigned_Negation_Uses_Carry_To_Trap;

   --  [0340]'s `not` takes a bool and gives one back, and [1870] fixes that
   --  bool at zero or one.  Flipping the low bit is therefore the whole
   --  operation; a width-wide `not` would give 254 for `not false`.
   procedure Logical_Not_Flips_The_One_Byte_Bool
     (Item : in out Landin.Testing.Context);

   procedure Logical_Not_Flips_The_One_Byte_Bool
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: bool) -> (r: bool) =" & LF
         & "    r = not a" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movb -3(%rbp), %al" & LF
           & HT & "xorb $1, %al" & LF
           & HT & "movb %al, -4(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "logical not flips the bool's low bit alone");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "notb %al"),
            "logical not is not a width-wide complement");
      end;
   end Logical_Not_Flips_The_One_Byte_Bool;

   --  [0330]'s `&`, `^` and `|` give their own integer type back, so each is
   --  one width-specific instruction with no edge and no signed variant.
   procedure Every_Bitwise_Operator_Selects_Its_Instruction
     (Item : in out Landin.Testing.Context);

   procedure Every_Bitwise_Operator_Selects_Its_Instruction
     (Item : in out Landin.Testing.Context)
   is
      type Case_Row is record
         Source      : access constant String;
         Instruction : access constant String;
      end record;

      And_Source : aliased constant String := "&";
      Xor_Source : aliased constant String := "^";
      Or_Source  : aliased constant String := "|";
      And_Text   : aliased constant String := "andl";
      Xor_Text   : aliased constant String := "xorl";
      Or_Text    : aliased constant String := "orl";

      Rows : constant array (1 .. 3) of Case_Row :=
        [(And_Source'Access, And_Text'Access),
         (Xor_Source'Access, Xor_Text'Access),
         (Or_Source'Access, Or_Text'Access)];
   begin
      for Row of Rows loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
            Ran  : Natural;
         begin
            Lower
              (Work,
               "f: (a: i32, b: i32) -> (r: i32) =" & LF
               & "    r = a " & Row.Source.all & " b" & LF & "end f" & LF,
               Ran);

            Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

            declare
               Text : constant String := Emitted (Work);
               Expected : constant String :=
                 HT & "movl -28(%rbp), %eax" & LF
                 & HT & Row.Instruction.all & " -24(%rbp), %eax" & LF
                 & HT & "movl %eax, -32(%rbp)" & LF;
            begin
               Landin.Testing.Check
                 (Item, Contains (Text, Expected),
                  Row.Source.all & " emits " & Row.Instruction.all
                  & " and stores immediately");
               Landin.Testing.Check
                 (Item, not Contains (Text, HT & "ud2"),
                  Row.Source.all & " has no trap edge");
            end;
         end;
      end loop;
   end Every_Bitwise_Operator_Selects_Its_Instruction;

   --  [0320] fills with zeros beyond the width for any amount, and x86-64
   --  masks the count instead -- five bits at 32-bit, six at 64 -- so
   --  `1u8 << 40` would shift by 8 on the bare hardware.  The width test is
   --  therefore the compiler's own and not the processor's.
   procedure Unsigned_Shift_Left_Zeroes_Beyond_The_Width
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_Shift_Left_Zeroes_Beyond_The_Width
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u8, s: u8) -> (r: u8) =" & LF
         & "    r = a << s" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movb -6(%rbp), %al" & LF
           & HT & "cmpb $8, %al" & LF
           & HT & "jb .L1_V5_inrange" & LF
           & HT & "movb $0, -8(%rbp)" & LF
           & HT & "jmp .L1_V5_done" & LF
           & ".L1_V5_inrange:" & LF
           & HT & "movb -6(%rbp), %cl" & LF
           & HT & "movb -7(%rbp), %al" & LF
           & HT & "shlb %cl, %al" & LF
           & HT & "movb %al, -8(%rbp)" & LF
           & ".L1_V5_done:" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "a u8 shift tests its own width before shifting");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "ud2"),
            "an unsigned amount cannot be negative and needs no trap");
      end;
   end Unsigned_Shift_Left_Zeroes_Beyond_The_Width;

   --  D6 gives the amount the left operand's type, so a signed left operand
   --  admits a negative amount and [1950] leaves the ones the compiler could
   --  not read to the trap.  A signed `>>` is the arithmetic one.
   procedure Signed_Shift_Right_Traps_A_Negative_Amount
     (Item : in out Landin.Testing.Context);

   procedure Signed_Shift_Right_Traps_A_Negative_Amount
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i32, s: i32) -> (r: i32) =" & LF
         & "    r = a >> s" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Guard : constant String :=
           HT & "movl -24(%rbp), %eax" & LF
           & HT & "cmpl $0, %eax" & LF
           & HT & "jge .L1_V5_nonnegative" & LF
           & HT & "ud2" & LF
           & ".L1_V5_nonnegative:" & LF
           & HT & "cmpl $32, %eax" & LF
           & HT & "jb .L1_V5_inrange" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Guard),
            "a negative amount traps before the width is tested");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "sarl %cl, %eax"),
            "a signed shift right is the arithmetic one");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "shrl %cl, %eax"),
            "a signed shift right is not the logical one");
      end;
   end Signed_Shift_Right_Traps_A_Negative_Amount;

   --  D13 settles the sentence [0320] left open: an amount at or past the
   --  width gives zero on every shift, and a signed `>>` is not the
   --  exception.  The width itself comes from the target description.
   procedure A_Signed_Shift_Beyond_The_Width_Is_Zero
     (Item : in out Landin.Testing.Context);

   procedure A_Signed_Shift_Beyond_The_Width_Is_Zero
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: isize, s: isize) -> (r: isize) =" & LF
         & "    r = a >> s" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Beyond : constant String :=
           HT & "cmpq $64, %rax" & LF
           & HT & "jb .L1_V5_inrange" & LF
           & HT & "movq $0, -64(%rbp)" & LF
           & HT & "jmp .L1_V5_done" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Beyond),
            "isize takes its width from the target and zeroes beyond it");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "sarq %cl, %rax"),
            "an amount below the width still keeps the sign");
      end;
   end A_Signed_Shift_Beyond_The_Width_Is_Zero;

   --  [1920] gives a call every parameter once and in order, and [1650]'s
   --  ABI says where those go.  The result comes back in the accumulator and
   --  becomes a frame cell like any other value.
   procedure A_Call_Fills_Its_Argument_Registers_In_Order
     (Item : in out Landin.Testing.Context);

   procedure A_Call_Fills_Its_Argument_Registers_In_Order
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "g: (a: i32, b: i32) -> (r: i32) =" & LF
         & "    r = a" & LF & "end g" & LF
         & "f: (x: i32) -> (r: i32) =" & LF
         & "    r = g(x, x)" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movl -24(%rbp), %edi" & LF
           & HT & "movl -20(%rbp), %esi" & LF
           & HT & "call g" & LF
           & HT & "movl %eax, -28(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "arguments reach their registers in order and the result a cell");
      end;
   end A_Call_Fills_Its_Argument_Registers_In_Order;

   --  [1920] gives a call of a function returning none no type at all, so
   --  there is nothing in the accumulator to keep and [1930] has no result to
   --  discard either.  A discarded scalar result still lands in its cell,
   --  because the discard is about who reads it and not about what ran.
   procedure A_Call_Returning_None_Keeps_Nothing
     (Item : in out Landin.Testing.Context);

   procedure A_Call_Returning_None_Keeps_Nothing
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "g: (a: i32) -> none =" & LF
         & "    _ = a" & LF & "end g" & LF
         & "f: (x: i32) -> none =" & LF
         & "    g(x)" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movl -8(%rbp), %edi" & LF
           & HT & "call g" & LF
           & HT & "movq %rbp, %rsp" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "a call returning none stores no result after it");
      end;
   end A_Call_Returning_None_Keeps_Nothing;

   --  [1650] hands six integer arguments in registers, and each is named at
   --  its own parameter's width rather than at one the call picks.
   procedure Six_Arguments_Reach_Their_Own_Widths
     (Item : in out Landin.Testing.Context);

   procedure Six_Arguments_Reach_Their_Own_Widths
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "g: (a: i8, b: i16, c: i32, d: i64, e: u8, h: usize)"
         & " -> (r: i8) =" & LF
         & "    r = a" & LF & "end g" & LF
         & "f: () -> (r: i8) =" & LF
         & "    r = g(1, 2, 3, 4, 5, 6)" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Registers : constant String :=
           HT & "movb -49(%rbp), %dil" & LF
           & HT & "movw -52(%rbp), %si" & LF
           & HT & "movl -56(%rbp), %edx" & LF
           & HT & "movq -64(%rbp), %rcx" & LF
           & HT & "movb -65(%rbp), %r8b" & LF
           & HT & "movq -48(%rbp), %r9" & LF
           & HT & "call g" & LF
           & HT & "movb %al, -66(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Registers),
            "each argument reaches its register at its own width");
      end;
   end Six_Arguments_Reach_Their_Own_Widths;

   --  R2.30 completes the scalar half of the internal convention: arguments
   --  after the six-register prefix occupy eight-byte stack slots in source
   --  order.  The caller rounds and reclaims the outgoing run; the callee
   --  reads past its return address and saved frame pointer before copying
   --  those values into ordinary slots.
   procedure Stack_Arguments_Cross_The_Call
     (Item : in out Landin.Testing.Context);

   procedure Stack_Arguments_Cross_The_Call
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "g: (a: i32, b: i32, c: i32, d: i32, e: i32, f: i32,"
         & " g: i32, h: i32) -> (r: i32) =" & LF
         & "    r = g + h" & LF & "end g" & LF
         & "f: () -> (r: i32) =" & LF
         & "    r = g(1, 2, 3, 4, 5, 6, 19, 23)" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Contains
              (Text,
               HT & "movl 16(%rbp), %eax" & LF
               & HT & "movl %eax, -28(%rbp)" & LF
               & HT & "movl 24(%rbp), %eax" & LF
               & HT & "movl %eax, -32(%rbp)" & LF),
            "the callee copies arguments seven and eight from stack slots");
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "subq $16, %rsp" & LF)
            and then Contains (Text, HT & "movl %eax, 0(%rsp)" & LF)
            and then Contains (Text, HT & "movl %eax, 8(%rsp)" & LF),
            "the caller fills one aligned outgoing stack run");
         Landin.Testing.Check
           (Item,
            Contains
              (Text,
               HT & "call g" & LF
               & HT & "addq $16, %rsp" & LF),
            "the caller reclaims the outgoing run immediately after return");
      end;
   end Stack_Arguments_Cross_The_Call;

   --  D94 preserves aggregate addresses before copying each argument into
   --  its own target-laid-out callee slot.  Register and stack positions use
   --  the same one-position internal convention.
   procedure Aggregate_Arguments_Are_Copied_In_The_Callee
     (Item : in out Landin.Testing.Context);

   procedure Aggregate_Arguments_Are_Copied_In_The_Callee
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "pair: type = struct" & LF
         & "    left: i32" & LF
         & "    row: [2]i32" & LF
         & "    right: i32" & LF
         & "end pair" & LF
         & "outer: type = struct" & LF
         & "    prefix: u8" & LF
         & "    nested: pair" & LF
         & "end outer" & LF
         & "take: (a: i32, first: pair, c: i32, d: i32, e: i32,"
         & " f: i32, second: [2]i32) -> (r: i32) =" & LF
         & "    r = first.left + second[1]" & LF
         & "end take" & LF
         & "use: () -> (r: i32) =" & LF
         & "    mut state: outer = zeroed" & LF
         & "    r = take(1, state.nested, 2, 3, 4, 5,"
         & " state.nested.row)" & LF
         & "end use" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "pushq %rsi" & LF)
              and then Contains (Text, HT & "pushq 16(%rbp)" & LF),
            "register and stack aggregate addresses are preserved");
         Landin.Testing.Check
           (Item,
            Occurrences (Text, HT & "popq %rsi" & LF) = 2
              and then Occurrences (Text, HT & "rep movsb" & LF) = 2,
            "each aggregate is copied into independent callee storage");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "addq %rdx, %rax" & LF),
            "the nested array address follows its target-derived offset");
      end;
   end Aggregate_Arguments_Are_Copied_In_The_Callee;

   --  A datum's block describes a value and is not code [1940], so it
   --  becomes an initialized object in `.data` at its own alignment rather
   --  than instructions anything runs.
   procedure A_Module_Value_Becomes_Initialized_Data
     (Item : in out Landin.Testing.Context);

   procedure A_Module_Value_Becomes_Initialized_Data
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower (Work, "public answer: i32 = 42" & LF, Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & ".data" & LF
           & HT & ".globl answer" & LF
           & HT & ".type answer, @object" & LF
           & HT & ".align 4" & LF
           & "answer:" & LF
           & HT & ".long 42" & LF
           & HT & ".size answer, 4" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "a module value is emitted as initialized data");
      end;
   end A_Module_Value_Becomes_Initialized_Data;

   --  [1740]'s module state of [0670]'s struct type.  D10 zeroes it, so
   --  what is emitted is [0750]'s whole size at [0750]'s own alignment and
   --  not a value per field.  `u32 u32 bool` reaches nine bytes and rounds
   --  to twelve, which is the tail padding an array of them would need.
   procedure A_Struct_State_Becomes_Zeroed_Data
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_State_Becomes_Zeroed_Data
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "counters: type = struct" & LF
         & "    hits: u32" & LF
         & "    misses: u32" & LF
         & "    ready: bool" & LF
         & "end counters" & LF
         & "public mut state: counters" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & ".bss" & LF
           & HT & ".globl state" & LF
           & HT & ".type state, @object" & LF
           & HT & ".align 4" & LF
           & "state:" & LF
           & HT & ".zero 12" & LF
           & HT & ".size state, 12" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "a struct state is emitted as its whole zeroed layout");
      end;
   end A_Struct_State_Becomes_Zeroed_Data;

   --  D59's explicit static zero image and D60/D61's typed and inferred copied
   --  images against two descriptions: an array field's element width and the
   --  aggregate's tail padding follow the target rather than the host.  Each
   --  absent image remains a distinct padded .bss object.
   procedure A_Struct_State_Follows_Its_Target
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_State_Follows_Its_Target
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "machine: type = struct" & LF
        & "    word: usize" & LF
        & "    row: [2]usize" & LF
        & "    ready: bool" & LF
        & "end machine" & LF
        & "mut state: machine = zeroed" & LF
        & "copy: machine = state" & LF
        & "mut inferred := copy" & LF;
   begin
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Synthetic_32);
         Ran  : Natural;
      begin
         Lower (Work, Source, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item,
               Contains (Text, HT & ".align 4" & LF & "state:" & LF
                               & HT & ".zero 16" & LF),
               "the array field uses the synthetic pointer width");
            Landin.Testing.Check
              (Item,
               Contains (Text, HT & ".align 4" & LF & "copy:" & LF
                               & HT & ".zero 16" & LF),
               "the copied image owns a second synthetic-width object");
            Landin.Testing.Check
              (Item,
               Contains (Text, HT & ".align 4" & LF & "inferred:" & LF
                               & HT & ".zero 16" & LF),
               "the inferred image owns a synthetic-width object");
         end;
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Ran  : Natural;
      begin
         Lower (Work, Source, Ran);

         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item,
               Contains (Text, HT & ".align 8" & LF & "state:" & LF
                               & HT & ".zero 32" & LF),
               "the array field uses the Linux pointer width");
            Landin.Testing.Check
              (Item,
               Contains (Text, HT & ".align 8" & LF & "copy:" & LF
                               & HT & ".zero 32" & LF),
               "the copied image owns a second Linux-width object");
            Landin.Testing.Check
              (Item,
               Contains (Text, HT & ".align 8" & LF & "inferred:" & LF
                               & HT & ".zero 32" & LF),
               "the inferred image owns a Linux-width object");
         end;
      end;
   end A_Struct_State_Follows_Its_Target;

   --  D66--D71 write scalar, finite, repeated and hybrid array-field folds at
   --  target-derived offsets.  D81--D83 do the same inside a selected variant
   --  payload, including direct and selected module image sources.
   procedure A_Module_Struct_Literal_Becomes_Data_Image
     (Item : in out Landin.Testing.Context);

   procedure A_Module_Struct_Literal_Becomes_Data_Image
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "machine: type = struct" & LF
        & "    tag: u8" & LF
        & "    word: usize" & LF
        & "    row: [2]u16" & LF
        & "    ready: bool" & LF
        & "end machine" & LF
        & "state: machine = (ready: true, row: [11, 13], word: 7,"
        & " tag: 5)" & LF
        & "blank: machine = (tag: 0, word: 0, row: zeroed,"
        & " ready: false)" & LF
        & "finite_zero: machine = (tag: 0, word: 0, row: [0, 0],"
        & " ready: false)" & LF
        & "patterns: type = struct" & LF
        & "    repeated: [2]usize" & LF
        & "    mixed: [3]u8" & LF
        & "end patterns" & LF
        & "pattern_state: patterns = (repeated: [of 7],"
        & " mixed: [1, of 2])" & LF
        & "zero_patterns: type = struct" & LF
        & "    mixed: [3]u8" & LF
        & "end zero_patterns" & LF
        & "zero_pattern_state: zero_patterns = (mixed: [0, of 0])" & LF
        & "choice: type = struct" & LF
        & "    kind: variant" & LF
        & "        leaf |" & LF
        & "        pair: (first: u8, second: u16) |" & LF
        & "        arrays: (finite: [2]u8, repeated: [2]u16,"
        & " hybrid: [3]u8, blank: [2]bool)" & LF
        & "    end kind" & LF
        & "end choice" & LF
        & "selected: choice = choice(kind: pair(first: 11,"
        & " second: 13))" & LF
        & "selected_copy: choice = selected" & LF
        & "selected_inferred := choice(kind: leaf)" & LF
        & "array_selected: choice = choice(kind: arrays("
        & "finite: [17, 19], repeated: [of 23],"
        & " hybrid: [29, of 31], blank: zeroed))" & LF
        & "array_selected_copy: choice = array_selected" & LF
        & "payload_holder: type = struct" & LF
        & "    repeated: [2]u16" & LF
        & "    blank: [2]bool" & LF
        & "end payload_holder" & LF
        & "array_copied: choice = choice(kind: arrays("
        & "finite: variant_finite_source,"
        & " repeated: variant_payload_fields.repeated,"
        & " hybrid: variant_hybrid_source,"
        & " blank: variant_payload_fields.blank))" & LF
        & "array_copied_copy: choice = array_copied" & LF
        & "variant_finite_source: [2]u8 = [43, 47]" & LF
        & "variant_hybrid_source: [3]u8 = [53, of 59]" & LF
        & "variant_payload_fields: payload_holder = ("
        & "repeated: [of 61], blank: [of false])" & LF;
   begin
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Synthetic_32);
         Ran : Natural;
         Expected : constant String :=
           HT & ".align 4" & LF
           & "state:" & LF
           & HT & ".byte 5" & LF
           & HT & ".zero 3" & LF
           & HT & ".long 7" & LF
           & HT & ".word 11" & LF
           & HT & ".word 13" & LF
           & HT & ".byte 1" & LF
           & HT & ".zero 3" & LF
           & HT & ".size state, 16" & LF;
      begin
         Lower (Work, Source, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item, Contains (Text, Expected),
               "the 32-bit image writes fields and zero layout gaps");
            Landin.Testing.Check
              (Item,
               Contains (Text, "blank:" & LF)
               and then Occurrences (Text, HT & ".data" & LF) = 1
               and then not Contains
                 (Text, "blank:" & LF & HT & ".zero 16" & LF),
               "an explicit all-zero literal remains written data");
            Landin.Testing.Check
              (Item,
               Contains
                 (Text,
                  "finite_zero:" & LF
                  & HT & ".byte 0" & LF
                  & HT & ".zero 3" & LF
                  & HT & ".long 0" & LF
                  & HT & ".word 0" & LF
                  & HT & ".word 0" & LF
                  & HT & ".byte 0" & LF
                  & HT & ".zero 3" & LF
                  & HT & ".size finite_zero, 16" & LF),
               "an all-zero finite field stays a written image");
            Landin.Testing.Check
              (Item,
               Contains
                 (Text,
                  "pattern_state:" & LF
                  & HT & ".rept 2" & LF
                  & HT & ".long 7" & LF
                  & HT & ".endr" & LF
                  & HT & ".byte 1" & LF
                  & HT & ".rept 2" & LF
                  & HT & ".byte 2" & LF
                  & HT & ".endr" & LF
                  & HT & ".zero 1" & LF
                  & HT & ".size pattern_state, 12" & LF),
               "32-bit repetition and hybrid fields retain target padding");
            Landin.Testing.Check
              (Item,
               Contains
                 (Text,
                  "zero_pattern_state:" & LF
                  & HT & ".byte 0" & LF
                  & HT & ".rept 2" & LF
                  & HT & ".byte 0" & LF
                  & HT & ".endr" & LF
                  & HT & ".size zero_pattern_state, 3" & LF),
               "an all-zero hybrid remains a written 32-bit image");
            Landin.Testing.Check
              (Item,
               Contains
                 (Text,
                  "selected:" & LF
                  & HT & ".byte 1" & LF
                  & HT & ".zero 1" & LF
                  & HT & ".byte 11" & LF
                  & HT & ".zero 1" & LF
                  & HT & ".word 13" & LF
                  & HT & ".zero 8" & LF
                  & HT & ".size selected, 14" & LF)
               and then Contains
                 (Text,
                  "selected_copy:" & LF
                  & HT & ".byte 1" & LF
                  & HT & ".zero 1" & LF
                  & HT & ".byte 11" & LF
                  & HT & ".zero 1" & LF
                  & HT & ".word 13" & LF
                  & HT & ".zero 8" & LF
                  & HT & ".size selected_copy, 14" & LF)
               and then Contains
                 (Text,
                  "selected_inferred:" & LF
                  & HT & ".byte 0" & LF
                  & HT & ".zero 13" & LF
                  & HT & ".size selected_inferred, 14" & LF),
               "selected variant images write tags, payloads and padding");
            Landin.Testing.Check
              (Item,
               Contains
                 (Text,
                  "array_selected:" & LF
                  & HT & ".byte 2" & LF
                  & HT & ".zero 1" & LF
                  & HT & ".byte 17" & LF
                  & HT & ".byte 19" & LF
                  & HT & ".rept 2" & LF
                  & HT & ".word 23" & LF
                  & HT & ".endr" & LF
                  & HT & ".byte 29" & LF
                  & HT & ".rept 2" & LF
                  & HT & ".byte 31" & LF
                  & HT & ".endr" & LF
                  & HT & ".zero 2" & LF
                  & HT & ".zero 1" & LF
                  & HT & ".size array_selected, 14" & LF)
               and then Contains
                 (Text,
                  "array_selected_copy:" & LF
                  & HT & ".byte 2" & LF
                  & HT & ".zero 1" & LF
                  & HT & ".byte 17" & LF
                  & HT & ".byte 19" & LF
                  & HT & ".rept 2" & LF
                  & HT & ".word 23" & LF
                  & HT & ".endr" & LF
                  & HT & ".byte 29" & LF
                  & HT & ".rept 2" & LF
                  & HT & ".byte 31" & LF
                  & HT & ".endr" & LF
                  & HT & ".zero 2" & LF
                  & HT & ".zero 1" & LF
                  & HT & ".size array_selected_copy, 14" & LF),
               "selected array payloads emit every compact image form");
            Landin.Testing.Check
              (Item,
               Contains
                 (Text,
                  "array_copied:" & LF
                  & HT & ".byte 2" & LF
                  & HT & ".zero 1" & LF
                  & HT & ".byte 43" & LF
                  & HT & ".byte 47" & LF
                  & HT & ".rept 2" & LF
                  & HT & ".word 61" & LF
                  & HT & ".endr" & LF
                  & HT & ".byte 53" & LF
                  & HT & ".rept 2" & LF
                  & HT & ".byte 59" & LF
                  & HT & ".endr" & LF
                  & HT & ".zero 2" & LF
                  & HT & ".zero 1" & LF
                  & HT & ".size array_copied, 14" & LF)
               and then Contains
                 (Text,
                  "array_copied_copy:" & LF
                  & HT & ".byte 2" & LF
                  & HT & ".zero 1" & LF
                  & HT & ".byte 43" & LF
                  & HT & ".byte 47" & LF
                  & HT & ".rept 2" & LF
                  & HT & ".word 61" & LF
                  & HT & ".endr" & LF
                  & HT & ".byte 53" & LF
                  & HT & ".rept 2" & LF
                  & HT & ".byte 59" & LF
                  & HT & ".endr" & LF
                  & HT & ".zero 2" & LF
                  & HT & ".zero 1" & LF
                  & HT & ".size array_copied_copy, 14" & LF),
               "selected image sources emit and copy on the 32-bit target");
         end;
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Ran : Natural;
         Expected : constant String :=
           HT & ".align 8" & LF
           & "state:" & LF
           & HT & ".byte 5" & LF
           & HT & ".zero 7" & LF
           & HT & ".quad 7" & LF
           & HT & ".word 11" & LF
           & HT & ".word 13" & LF
           & HT & ".byte 1" & LF
           & HT & ".zero 3" & LF
           & HT & ".size state, 24" & LF;
      begin
         Lower (Work, Source, Ran);
         Landin.Testing.Check
           (Item, Contains (Emitted (Work), Expected),
            "the same target-neutral image follows 64-bit placement");
         Landin.Testing.Check
           (Item,
            Contains
              (Emitted (Work),
               "finite_zero:" & LF
               & HT & ".byte 0" & LF
               & HT & ".zero 7" & LF
               & HT & ".quad 0" & LF
               & HT & ".word 0" & LF
               & HT & ".word 0" & LF
               & HT & ".byte 0" & LF
               & HT & ".zero 3" & LF
               & HT & ".size finite_zero, 24" & LF),
            "the finite zero image follows 64-bit placement");
         Landin.Testing.Check
           (Item,
            Contains
              (Emitted (Work),
               "pattern_state:" & LF
               & HT & ".rept 2" & LF
               & HT & ".quad 7" & LF
               & HT & ".endr" & LF
               & HT & ".byte 1" & LF
               & HT & ".rept 2" & LF
               & HT & ".byte 2" & LF
               & HT & ".endr" & LF
               & HT & ".zero 5" & LF
               & HT & ".size pattern_state, 24" & LF),
            "64-bit repetition and hybrid fields retain target padding");
         Landin.Testing.Check
           (Item,
            Contains
              (Emitted (Work),
               "zero_pattern_state:" & LF
               & HT & ".byte 0" & LF
               & HT & ".rept 2" & LF
               & HT & ".byte 0" & LF
               & HT & ".endr" & LF
               & HT & ".size zero_pattern_state, 3" & LF),
            "an all-zero hybrid remains a written 64-bit image");
         Landin.Testing.Check
           (Item,
            Contains
              (Emitted (Work),
               "selected:" & LF
               & HT & ".byte 1" & LF
               & HT & ".zero 1" & LF
               & HT & ".byte 11" & LF
               & HT & ".zero 1" & LF
               & HT & ".word 13" & LF
               & HT & ".zero 8" & LF
               & HT & ".size selected, 14" & LF),
            "the same selected image follows 64-bit placement");
         Landin.Testing.Check
           (Item,
            Contains
              (Emitted (Work),
               "array_selected:" & LF
               & HT & ".byte 2" & LF
               & HT & ".zero 1" & LF
               & HT & ".byte 17" & LF
               & HT & ".byte 19" & LF
               & HT & ".rept 2" & LF
               & HT & ".word 23" & LF
               & HT & ".endr" & LF
               & HT & ".byte 29" & LF
               & HT & ".rept 2" & LF
               & HT & ".byte 31" & LF
               & HT & ".endr" & LF
               & HT & ".zero 2" & LF
               & HT & ".zero 1" & LF
               & HT & ".size array_selected, 14" & LF),
            "selected array payloads are target-neutral folds");
         Landin.Testing.Check
           (Item,
            Contains
              (Emitted (Work),
               "array_copied:" & LF
               & HT & ".byte 2" & LF
               & HT & ".zero 1" & LF
               & HT & ".byte 43" & LF
               & HT & ".byte 47" & LF
               & HT & ".rept 2" & LF
               & HT & ".word 61" & LF
               & HT & ".endr" & LF
               & HT & ".byte 53" & LF
               & HT & ".rept 2" & LF
               & HT & ".byte 59" & LF
               & HT & ".endr" & LF
               & HT & ".zero 2" & LF
               & HT & ".zero 1" & LF
               & HT & ".size array_copied, 14" & LF),
            "selected image sources stay target-neutral on 64-bit");
      end;
   end A_Module_Struct_Literal_Becomes_Data_Image;

   --  D132 replays every nested child and aggregate payload placement after
   --  target selection.  The one neutral descriptor tree therefore emits
   --  different usize widths and padding on the 32- and 64-bit facts.
   procedure A_Recursive_Module_Image_Follows_Its_Target
     (Item : in out Landin.Testing.Context);

   procedure A_Recursive_Module_Image_Follows_Its_Target
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "word: type = struct" & LF
        & "    value: usize" & LF
        & "    code: u8" & LF
        & "end word" & LF
        & "packet: type = struct" & LF
        & "    head: u8" & LF
        & "    child: word" & LF
        & "    tail: u16" & LF
        & "end packet" & LF
        & "choice: type = struct" & LF
        & "    kind: variant" & LF
        & "        empty |" & LF
        & "        carry: (data: packet)" & LF
        & "    end kind" & LF
        & "end choice" & LF
        & "image: choice = choice(kind: carry(data: packet(head: 11,"
        & " child: word(value: 42, code: 7), tail: 13)))" & LF
        & "copy: choice = image" & LF;
   begin
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Synthetic_32);
         Ran : Natural;
         Expected : constant String :=
           "image:" & LF
           & HT & ".byte 1" & LF
           & HT & ".zero 3" & LF
           & HT & ".byte 11" & LF
           & HT & ".zero 3" & LF
           & HT & ".long 42" & LF
           & HT & ".byte 7" & LF
           & HT & ".zero 3" & LF
           & HT & ".word 13" & LF
           & HT & ".zero 2" & LF
           & HT & ".size image, 20" & LF;
      begin
         Lower (Work, Source, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item, Contains (Text, Expected),
               "the recursive image follows 32-bit placement");
            Landin.Testing.Check
              (Item,
               Contains
                 (Text, "copy:" & LF & HT & ".byte 1" & LF)
               and then Contains (Text, HT & ".size copy, 20" & LF),
               "the copied descriptor tree emits a second 32-bit object");
         end;
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Ran : Natural;
         Expected : constant String :=
           "image:" & LF
           & HT & ".byte 1" & LF
           & HT & ".zero 7" & LF
           & HT & ".byte 11" & LF
           & HT & ".zero 7" & LF
           & HT & ".quad 42" & LF
           & HT & ".byte 7" & LF
           & HT & ".zero 7" & LF
           & HT & ".word 13" & LF
           & HT & ".zero 6" & LF
           & HT & ".size image, 40" & LF;
      begin
         Lower (Work, Source, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item, Contains (Text, Expected),
               "the same recursive image follows 64-bit placement");
            Landin.Testing.Check
              (Item,
               Contains
                 (Text, "copy:" & LF & HT & ".byte 1" & LF)
               and then Contains (Text, HT & ".size copy, 40" & LF),
               "the copied descriptor tree emits a second 64-bit object");
         end;
      end;
   end A_Recursive_Module_Image_Follows_Its_Target;

   --  [0750] puts each field at its own offset, and a selection reaches
   --  one by adding that many bytes to the datum's name.  The first field
   --  needs no displacement at all, which is what says the offset is the
   --  layout's and not a number this backend invented.
   procedure A_Field_Is_Read_At_Its_Own_Offset
     (Item : in out Landin.Testing.Context);

   procedure A_Field_Is_Read_At_Its_Own_Offset
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "counters: type = struct" & LF
         & "    hits: u32" & LF
         & "    misses: u32" & LF
         & "    ready: bool" & LF
         & "end counters" & LF
         & "mut state: counters" & LF
         & "read: () -> none =" & LF
         & "    a: u32 = state.hits" & LF
         & "    b: u32 = state.misses" & LF
         & "    c: bool = state.ready" & LF
         & "end read" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movl state(%rip), %eax"),
            "the first field is the datum's own address");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movl state+4(%rip), %eax"),
            "the second field is four bytes along");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movb state+8(%rip), %al"),
            "and the bool is one byte at eight");
      end;
   end A_Field_Is_Read_At_Its_Own_Offset;

   --  D46 can put a scalar sibling beyond the signed displacement of an
   --  x86-64 memory operand.  Like D18's far array element, the backend
   --  must form that address in registers rather than ask the assembler
   --  and loader to encode an impossible symbol-plus-offset relocation.
   procedure A_Field_After_A_Wide_Array_Uses_A_Register_Address
     (Item : in out Landin.Testing.Context);

   procedure A_Field_After_A_Wide_Array_Uses_A_Register_Address
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "wide: type = struct" & LF
         & "    prefix: [2147483648]u8" & LF
         & "    tail: u8" & LF
         & "end wide" & LF
         & "mut state: wide" & LF
         & "read: () -> none =" & LF
         & "    value: u8 = state.tail" & LF
         & "end read" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "leaq state(%rip), %rcx"),
            "the wide sibling offset starts from the symbol address");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movabsq $2147483648, %rdx")
                  and then Contains (Text, HT & "addq %rdx, %rcx")
                  and then Contains (Text, HT & "movb (%rcx), %al"),
            "the full target offset is added and then loaded");
      end;
   end A_Field_After_A_Wide_Array_Uses_A_Register_Address;

   procedure An_Array_Field_After_A_Wide_Field_Uses_Registers
     (Item : in out Landin.Testing.Context);

   procedure An_Array_Field_After_A_Wide_Field_Uses_Registers
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "wide: type = struct" & LF
         & "    prefix: [2147483648]u8" & LF
         & "    row: [2]u8" & LF
         & "end wide" & LF
         & "state: wide" & LF
         & "read: (i: usize) -> (r: u8) =" & LF
         & "    r = state.row[i]" & LF
         & "end read" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "cmpq %rdx, %rax")
            and then Contains (Text, HT & "leaq state(%rip), %rcx")
            and then Contains
                       (Text, HT & "movabsq $2147483648, %rdx")
            and then Contains (Text, HT & "addq %rdx, %rcx")
            and then Contains (Text, HT & "addq %rax, %rcx"),
            "the trap precedes a full-width field offset and scaled index");
      end;
   end An_Array_Field_After_A_Wide_Field_Uses_Registers;

   --  D52 reuses D48's field-qualified element-store path for every literal
   --  position.  A far module field is register-formed for each store;
   --  a frame field and its element scale follow the selected target.
   procedure Array_Field_Literal_Stores_Follow_Their_Target
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Literal_Stores_Follow_Their_Target
     (Item : in out Landin.Testing.Context)
   is
      Wide : constant String :=
        "wide: type = struct" & LF
        & "    prefix: [2147483648]u8" & LF
        & "    row: [2]u8" & LF
        & "end wide" & LF
        & "mut state: wide" & LF
        & "write: () -> none =" & LF
        & "    state.row = [20, 22]" & LF
        & "end write" & LF;
      Local : constant String :=
        "holder: type = struct" & LF
        & "    tag: u8" & LF
        & "    row: [2]usize" & LF
        & "    tail: u16" & LF
        & "end holder" & LF
        & "write: () -> none =" & LF
        & "    mut local: holder" & LF
        & "    local.row = [20, 22]" & LF
        & "end write" & LF;

      procedure Check_Local
        (Facts : Landin.Targets.Target_Facts;
         Field : String;
         Scale : String);

      procedure Check_Local
        (Facts : Landin.Targets.Target_Facts;
         Field : String;
         Scale : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran : Natural;
      begin
         Lower (Work, Local, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item,
               Occurrences (Text, HT & "leaq " & Field & "(%rbp), %rcx") = 2
               and then Occurrences
                 (Text, HT & "imulq $" & Scale & ", %rax, %rax") = 2,
               "both local stores use the target field and element width");
         end;
      end Check_Local;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower (Work, Wide, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Occurrences (Text, HT & "leaq state(%rip), %rcx") = 2
            and then Occurrences
              (Text, HT & "movabsq $2147483648, %rdx") = 2
            and then Occurrences (Text, HT & "addq %rdx, %rcx") = 2,
            "each far module-field store forms the full-width address");
      end;

      Check_Local (Landin.Targets.Linux_X86_64, "-24", "8");
      Check_Local (Landin.Targets.Synthetic_32, "-12", "4");
   end Array_Field_Literal_Stores_Follow_Their_Target;

   --  D53 composes the target-derived containing-field address with D37's
   --  suffix offset.  A far module field is register-formed; a local field
   --  remains an L0504-bounded displacement on both target descriptions.
   procedure Array_Field_Repetition_Fills_Follow_Their_Target
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Repetition_Fills_Follow_Their_Target
     (Item : in out Landin.Testing.Context)
   is
      Wide : constant String :=
        "wide: type = struct" & LF
        & "    prefix: [2147483648]u8" & LF
        & "    row: [4]u32" & LF
        & "end wide" & LF
        & "mut state: wide" & LF
        & "write: () -> none =" & LF
        & "    state.row = [1, 2, of 3]" & LF
        & "end write" & LF;
      Local : constant String :=
        "holder: type = struct" & LF
        & "    tag: u8" & LF
        & "    row: [4]usize" & LF
        & "    tail: u16" & LF
        & "end holder" & LF
        & "write: () -> none =" & LF
        & "    mut local: holder" & LF
        & "    local.row = [1, 2, of 3]" & LF
        & "end write" & LF;

      procedure Check_Local
        (Facts  : Landin.Targets.Target_Facts;
         Field  : String;
         Suffix : String;
         Store  : String);

      procedure Check_Local
        (Facts  : Landin.Targets.Target_Facts;
         Field  : String;
         Suffix : String;
         Store  : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran : Natural;
      begin
         Lower (Work, Local, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item,
               Contains (Text, HT & "leaq " & Field & "(%rbp), %rdi")
               and then Contains (Text, HT & "addq $" & Suffix & ", %rdi")
               and then Contains (Text, HT & "movabsq $2, %rcx")
               and then Contains (Text, HT & "rep " & Store),
               "the local suffix fill follows target layout and width");
         end;
      end Check_Local;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower (Work, Wide, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "leaq state(%rip), %rdi")
            and then Contains
              (Text, HT & "movabsq $2147483648, %rdx")
            and then Contains (Text, HT & "addq %rdx, %rdi")
            and then Contains (Text, HT & "addq $8, %rdi")
            and then Contains (Text, HT & "movabsq $2, %rcx")
            and then Contains (Text, HT & "rep stosl"),
            "the wide module suffix composes field and prefix offsets");
      end;

      Check_Local (Landin.Targets.Linux_X86_64, "-40", "16", "stosq");
      Check_Local (Landin.Targets.Synthetic_32, "-20", "8", "stosl");
   end Array_Field_Repetition_Fills_Follow_Their_Target;

   --  D54's whole struct copy delegates each fixed-array field to D50.
   --  A wide module field therefore forms both addresses in registers, and
   --  a local-to-local field copy follows the selected frame layout.
   procedure Array_Bearing_Struct_Copy_Derives_Field_Addresses
     (Item : in out Landin.Testing.Context);

   procedure Array_Bearing_Struct_Copy_Derives_Field_Addresses
     (Item : in out Landin.Testing.Context)
   is
      Wide : constant String :=
        "wide: type = struct" & LF
        & "    prefix: [2147483648]u8" & LF
        & "    row: [2]u8" & LF
        & "    tail: u16" & LF
        & "end wide" & LF
        & "mut source: wide" & LF
        & "mut destination: wide" & LF
        & "copy: () -> none =" & LF
        & "    destination = source" & LF
        & "end copy" & LF;
      Local : constant String :=
        "holder: type = struct" & LF
        & "    tag: u8" & LF
        & "    row: [2]usize" & LF
        & "    tail: u16" & LF
        & "end holder" & LF
        & "copy: () -> none =" & LF
        & "    mut source: holder" & LF
        & "    source.tag = 1" & LF
        & "    source.row = zeroed" & LF
        & "    source.tail = 2" & LF
        & "    mut destination: holder" & LF
        & "    destination = source" & LF
        & "end copy" & LF;

      procedure Check_Local
        (Facts       : Landin.Targets.Target_Facts;
         Destination : String;
         Source      : String;
         Bytes       : String);

      procedure Check_Local
        (Facts       : Landin.Targets.Target_Facts;
         Destination : String;
         Source      : String;
         Bytes       : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran : Natural;
      begin
         Lower (Work, Local, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item,
               Contains
                 (Text, HT & "leaq " & Destination & "(%rbp), %rdi")
               and then Contains
                 (Text, HT & "leaq " & Source & "(%rbp), %rsi")
               and then Contains
                 (Text, HT & "movabsq $" & Bytes & ", %rcx")
               and then Contains (Text, HT & "rep movsb"),
               "the local array field copy follows target frame layout");
         end;
      end Check_Local;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower (Work, Wide, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "leaq destination(%rip), %rdi")
            and then Contains (Text, HT & "leaq source(%rip), %rsi")
            and then Occurrences
              (Text, HT & "movabsq $2147483648, %rdx") >= 2
            and then Contains (Text, HT & "addq %rdx, %rdi")
            and then Contains (Text, HT & "addq %rdx, %rsi")
            and then Contains (Text, HT & "movabsq $2, %rcx")
            and then Contains (Text, HT & "rep movsb"),
            "the wide module array field forms both complete addresses");
      end;

      Check_Local (Landin.Targets.Linux_X86_64, "-56", "-24", "16");
      Check_Local (Landin.Targets.Synthetic_32, "-28", "-12", "8");
   end Array_Bearing_Struct_Copy_Derives_Field_Addresses;

   --  D55's destination is a fresh aggregate frame slot.  Its fixed-array
   --  field therefore composes D54's compact copy with the target-derived
   --  module field address and frame field displacement.
   procedure Local_Struct_Initializer_Derives_Field_Addresses
     (Item : in out Landin.Testing.Context);

   procedure Local_Struct_Initializer_Derives_Field_Addresses
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "holder: type = struct" & LF
        & "    tag: u8" & LF
        & "    row: [2]usize" & LF
        & "    tail: u16" & LF
        & "end holder" & LF
        & "source: holder" & LF
        & "copy: () -> none =" & LF
        & "    local: holder = source" & LF
        & "    empty: holder = zeroed" & LF
        & "end copy" & LF;

      procedure Check_Target
        (Facts        : Landin.Targets.Target_Facts;
         Destination : String;
         Field_Offset : String;
         Bytes        : String;
         Clear_At     : String;
         Clear_Bytes  : String);

      procedure Check_Target
        (Facts        : Landin.Targets.Target_Facts;
         Destination : String;
         Field_Offset : String;
         Bytes        : String;
         Clear_At     : String;
         Clear_Bytes  : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran : Natural;
      begin
         Lower (Work, Source, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item,
               Contains
                 (Text, HT & "leaq " & Destination & "(%rbp), %rdi")
               and then Contains (Text, HT & "leaq source(%rip), %rsi")
               and then Contains
                 (Text, HT & "movabsq $" & Field_Offset & ", %rdx")
               and then Contains (Text, HT & "addq %rdx, %rsi")
               and then Contains
                 (Text, HT & "movabsq $" & Bytes & ", %rcx")
               and then Contains (Text, HT & "rep movsb")
               and then Contains
                 (Text, HT & "leaq " & Clear_At & "(%rbp), %rdi")
               and then Contains
                 (Text, HT & "movabsq $" & Clear_Bytes & ", %rcx")
               and then Contains (Text, HT & "rep stosb"),
               "the initialized field addresses follow the target");
         end;
      end Check_Target;
   begin
      Check_Target
        (Landin.Targets.Linux_X86_64, "-24", "8", "16", "-64", "32");
      Check_Target
        (Landin.Targets.Synthetic_32, "-12", "4", "8", "-32", "16");
   end Local_Struct_Initializer_Derives_Field_Addresses;

   --  D56 reuses the same fresh-slot copy after inference carried the source
   --  identity.  Target facts still derive both the frame displacement and
   --  the module field address.
   procedure Inferred_Local_Struct_Derives_Field_Addresses
     (Item : in out Landin.Testing.Context);

   procedure Inferred_Local_Struct_Derives_Field_Addresses
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "holder: type = struct" & LF
        & "    tag: u8" & LF
        & "    row: [2]usize" & LF
        & "    tail: u16" & LF
        & "end holder" & LF
        & "source: holder" & LF
        & "copy: () -> none =" & LF
        & "    local := source" & LF
        & "end copy" & LF;

      procedure Check_Target
        (Facts        : Landin.Targets.Target_Facts;
         Destination : String;
         Field_Offset : String;
         Bytes        : String);

      procedure Check_Target
        (Facts        : Landin.Targets.Target_Facts;
         Destination : String;
         Field_Offset : String;
         Bytes        : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran : Natural;
      begin
         Lower (Work, Source, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item,
               Contains
                 (Text, HT & "leaq " & Destination & "(%rbp), %rdi")
               and then Contains (Text, HT & "leaq source(%rip), %rsi")
               and then Contains
                 (Text, HT & "movabsq $" & Field_Offset & ", %rdx")
               and then Contains (Text, HT & "addq %rdx, %rsi")
               and then Contains
                 (Text, HT & "movabsq $" & Bytes & ", %rcx")
               and then Contains (Text, HT & "rep movsb"),
               "inferred local field addresses follow the target");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, "-24", "8", "16");
      Check_Target (Landin.Targets.Synthetic_32, "-12", "4", "8");
   end Inferred_Local_Struct_Derives_Field_Addresses;

   --  D49 clears the same far field from its register-formed module address;
   --  the byte count is the field extent, not the containing datum extent.
   procedure A_Wide_Array_Field_Clear_Uses_Registers
     (Item : in out Landin.Testing.Context);

   procedure A_Wide_Array_Field_Clear_Uses_Registers
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "wide: type = struct" & LF
         & "    prefix: [2147483648]u8" & LF
         & "    row: [2]u8" & LF
         & "end wide" & LF
         & "mut state: wide" & LF
         & "clear: () -> none =" & LF
         & "    state.row = zeroed" & LF
         & "end clear" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "leaq state(%rip), %rdi")
            and then Contains
                       (Text, HT & "movabsq $2147483648, %rdx")
            and then Contains (Text, HT & "addq %rdx, %rdi")
            and then Contains (Text, HT & "movabsq $2, %rcx")
            and then Contains (Text, HT & "rep stosb"),
            "the full field offset is added before its two bytes clear");
      end;
   end A_Wide_Array_Field_Clear_Uses_Registers;

   --  D50 derives both copy endpoints from the selected target.  A module
   --  field behind D18's wide prefix is register-formed on either side;
   --  frame fields use the L0504-bounded target displacement.
   procedure Array_Field_Copy_Derives_Both_Target_Addresses
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Copy_Derives_Both_Target_Addresses
     (Item : in out Landin.Testing.Context)
   is
      Wide : constant String :=
        "wide: type = struct" & LF
        & "    prefix: [2147483648]u8" & LF
        & "    row: [2]u8" & LF
        & "end wide" & LF
        & "mut source: wide" & LF
        & "mut destination: wide" & LF
        & "copy: () -> none =" & LF
        & "    destination.row = source.row" & LF
        & "end copy" & LF;
      Local : constant String :=
        "holder: type = struct" & LF
        & "    tag: u8" & LF
        & "    row: [2]usize" & LF
        & "    tail: u16" & LF
        & "end holder" & LF
        & "copy: () -> none =" & LF
        & "    mut source: holder" & LF
        & "    mut destination: holder" & LF
        & "    source.row = zeroed" & LF
        & "    destination.row = source.row" & LF
        & "end copy" & LF;

      procedure Check_Local
        (Facts : Landin.Targets.Target_Facts;
         Destination_Field : String;
         Source_Field : String;
         Bytes : String);

      procedure Check_Local
        (Facts : Landin.Targets.Target_Facts;
         Destination_Field : String;
         Source_Field : String;
         Bytes : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran : Natural;
      begin
         Lower (Work, Local, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item,
               Contains
                 (Text,
                  HT & "leaq " & Destination_Field & "(%rbp), %rdi" & LF
                  & HT & "leaq " & Source_Field & "(%rbp), %rsi" & LF
                  & HT & "movabsq $" & Bytes & ", %rcx" & LF
                  & HT & "cld" & LF
                  & HT & "rep movsb" & LF),
               "both frame field addresses and the extent follow the target");
         end;
      end Check_Local;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower (Work, Wide, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "leaq destination(%rip), %rdi")
            and then Contains (Text, HT & "addq %rdx, %rdi")
            and then Contains (Text, HT & "leaq source(%rip), %rsi")
            and then Contains (Text, HT & "addq %rdx, %rsi")
            and then Occurrences
              (Text, HT & "movabsq $2147483648, %rdx") = 2
            and then Contains (Text, HT & "movabsq $2, %rcx")
            and then Contains (Text, HT & "rep movsb"),
            "both wide module field offsets are formed in registers");
      end;

      Check_Local (Landin.Targets.Linux_X86_64, "-56", "-24", "16");
      Check_Local (Landin.Targets.Synthetic_32, "-28", "-12", "8");
   end Array_Field_Copy_Derives_Both_Target_Addresses;

   --  D51's fresh destination is direct array storage in the frame while its
   --  source may be a D18-wide module field.  The field identity therefore
   --  takes D50's register-formed source path on either target description.
   procedure Array_Field_Initializer_Derives_Its_Source_Address
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Initializer_Derives_Its_Source_Address
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "wide: type = struct" & LF
        & "    prefix: [2147483648]u8" & LF
        & "    row: [2]u8" & LF
        & "end wide" & LF
        & "source: wide" & LF
        & "copy: () -> none =" & LF
        & "    local: [2]u8 = source.row" & LF
        & "end copy" & LF;

      procedure Check_Target (Facts : Landin.Targets.Target_Facts);

      procedure Check_Target (Facts : Landin.Targets.Target_Facts) is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran : Natural;
      begin
         Lower (Work, Source, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item,
               Contains
                 (Text,
                  HT & "leaq -2(%rbp), %rdi" & LF
                  & HT & "leaq source(%rip), %rsi" & LF
                  & HT & "movabsq $2147483648, %rdx" & LF
                  & HT & "addq %rdx, %rsi" & LF
                  & HT & "movabsq $2, %rcx" & LF
                  & HT & "cld" & LF
                  & HT & "rep movsb" & LF),
               "the fresh slot and wide field source follow the target");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64);
      Check_Target (Landin.Targets.Synthetic_32);
   end Array_Field_Initializer_Derives_Its_Source_Address;

   --  A field is written where it is read [1810], and `inc` on one says
   --  what `x += 1` says [1900]: a load at the offset, a one, a trapping
   --  add and a store back to the same offset.
   procedure A_Field_Is_Written_At_Its_Own_Offset
     (Item : in out Landin.Testing.Context);

   procedure A_Field_Is_Written_At_Its_Own_Offset
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "counters: type = struct" & LF
         & "    hits: u32" & LF
         & "    misses: u32" & LF
         & "    ready: bool" & LF
         & "end counters" & LF
         & "mut state: counters" & LF
         & "write: () -> none =" & LF
         & "    state.hits = 7" & LF
         & "    state.ready = true" & LF
         & "    inc state.misses" & LF
         & "end write" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movl %eax, state(%rip)"),
            "the first field is written at the datum's own address");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movb %al, state+8(%rip)"),
            "and the bool is one byte at eight");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movl state+4(%rip), %eax"),
            "a step reads the field it steps");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movl %eax, state+4(%rip)"),
            "and writes the answer back to the same bytes");
      end;
   end A_Field_Is_Written_At_Its_Own_Offset;

   --  [1810]'s local of a struct type is a cell in the frame, and a cell
   --  grows downward while [0750] lays a struct out upward: field 1 is
   --  furthest below the frame pointer and the last field is nearest, so
   --  a hexdump of the cell reads in source order.  Two of them in one
   --  frame do not overlap, which the second cell's own offsets say.
   procedure A_Struct_Local_Is_A_Cell_In_The_Frame
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_Local_Is_A_Cell_In_The_Frame
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "counters: type = struct" & LF
         & "    hits: u32" & LF
         & "    misses: u32" & LF
         & "    ready: bool" & LF
         & "end counters" & LF
         & "use: () -> none =" & LF
         & "    mut p: counters" & LF
         & "    p.hits = 1" & LF
         & "    p.misses = 2" & LF
         & "    p.ready = true" & LF
         & "end use" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movl %eax, -12(%rbp)"),
            "the first field is at the bottom of the cell");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movl %eax, -8(%rbp)"),
            "the second is four bytes above it");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movb %al, -4(%rbp)"),
            "and the bool is one byte at eight");
      end;
   end A_Struct_Local_Is_A_Cell_In_The_Frame;

   --  D47 replays a compact array-field shape inside [1810]'s one frame
   --  cell.  Both the cell extent and the trailing scalar's address follow
   --  the selected target's usize width rather than the host.
   procedure A_Struct_Array_Field_Local_Follows_Its_Target
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_Array_Field_Local_Follows_Its_Target
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "holder: type = struct" & LF
        & "    tag: u8" & LF
        & "    words: [2]usize" & LF
        & "    tail: u16" & LF
        & "end holder" & LF
        & "f: () -> none =" & LF
        & "    mut local: holder" & LF
        & "    local.tag = 1" & LF
        & "    local.words = zeroed" & LF
        & "    local.words[0] = 1" & LF
        & "    local.words[1] = 2" & LF
        & "    at: usize = 1" & LF
        & "    local.words[at] = 3" & LF
        & "    local.tail = 2" & LF
        & "end f" & LF;

      procedure Check_Target
        (Facts       : Landin.Targets.Target_Facts;
         First_Cell  : String;
         Array_Field : String;
         Last_Field  : String);

      procedure Check_Target
        (Facts       : Landin.Targets.Target_Facts;
         First_Cell  : String;
         Array_Field : String;
         Last_Field  : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran  : Natural;
      begin
         Lower (Work, Source, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item, Contains (Text, HT & "movb %al, " & First_Cell
                                      & "(%rbp)"),
               "the first scalar begins the target-sized cell");
            Landin.Testing.Check
              (Item, Contains (Text, HT & "leaq " & Array_Field
                                      & "(%rbp), %rcx"),
               "the computed element starts at the target-laid-out field");
            Landin.Testing.Check
              (Item, Contains (Text, HT & "leaq " & Array_Field
                                      & "(%rbp), %rdi"),
               "the clear starts at the same target-laid-out field");
            Landin.Testing.Check
              (Item, Contains (Text, HT & "movw %ax, " & Last_Field
                                      & "(%rbp)"),
               "the trailing scalar follows the compact array field");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, "-32", "-24", "-8");
      Check_Target (Landin.Targets.Synthetic_32, "-16", "-12", "-4");
   end A_Struct_Array_Field_Local_Follows_Its_Target;

   --  D136 admits D17's empty fixed-array source shape. When one reaches
   --  D47's slot field run it takes no bytes and imposes alignment one,
   --  exactly as in D45 and D46.
   procedure An_Empty_Array_Slot_Field_Has_Identity_Extent
     (Item : in out Landin.Testing.Context);

   procedure An_Empty_Array_Slot_Field_Has_Identity_Extent
     (Item : in out Landin.Testing.Context)
   is
      Work      : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran       : Natural;
      Unit      : IR.Unit;
      Routine   : IR.Item_Id;
      Slot, Other : IR.Slot_Id;
      Size      : Landin.Targets.Byte_Count;
      Alignment : Landin.Targets.Byte_Alignment;
      Site      : constant Landin.Provenance.Origin :=
        (Source => 1, Where => Landin.Source.Empty_Span);
   begin
      Lower (Work, "f: () -> none = end f" & LF, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
      Routine := IR.Add_Item
        (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
      Slot := IR.Add_Aggregate_Slot
        (Unit, Routine, IR.No_Declaration, Site);
      IR.Add_Slot_Field
        (Unit, Routine, Slot,
         (Kind    => IR.Array_Field_Shape,
          Element => Landin.Types.U64,
          Length  => 0,
          others  => <>));
      Other := IR.Add_Aggregate_Slot
        (Unit, Routine, IR.No_Declaration, Site);
      IR.Add_Slot_Field
        (Unit, Routine, Other,
         (Kind    => IR.Array_Field_Shape,
          Element => Landin.Types.U64,
          Length  => 0,
          others  => <>));
      Landin.Backend.Aggregate_Extent
        (Unit, Routine, Slot, Landin.Targets.Linux_X86_64,
         Size, Alignment);

      Landin.Testing.Check
        (Item, Size = 0, "the empty field contributes no bytes");
      Landin.Testing.Check
        (Item, Alignment = 1,
         "the empty field contributes identity alignment");

      declare
         Block : constant IR.Block_Id :=
           IR.Add_Block
             (Unit, Routine, Landin.Resolution.Program_Scope, Site);
      begin
         IR.Enter (Unit, Routine, Block);
         IR.Emit_Array_Clear
           (Unit, Routine, (Kind => IR.Frame_Slot, Slot => Slot), Site,
            Field => 1);
         IR.Emit_Array_Copy
           (Unit, Routine, (Kind => IR.Frame_Slot, Slot => Slot),
            (Kind => IR.Frame_Slot, Slot => Other), Site,
            Source_Field => 1, Destination_Field => 1);
         IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
         IR.Leave_Block (Unit, Routine);

         declare
            Text : constant String :=
              Landin.Backend.X86_64.Text
                (Unit, Landin.Stages.Meanings (Work).all,
                 Landin.Stages.Identities (Work).all,
                 Landin.Targets.Linux_X86_64);
         begin
            Landin.Testing.Check
              (Item,
               Occurrences (Text, HT & "movabsq $0, %rcx") = 2
               and then Contains (Text, HT & "rep stosb")
               and then Contains (Text, HT & "rep movsb"),
               "clearing and copying the empty field are zero-byte ops");
         end;
      end;
   end An_Empty_Array_Slot_Field_Has_Identity_Extent;

   procedure Constant_Array_Parts_Address_One_Frame_Cell
     (Item : in out Landin.Testing.Context);

   procedure Constant_Array_Parts_Address_One_Frame_Cell
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower (Work, "use: () -> none = end use" & LF, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Unit : IR.Unit;
         Routine : IR.Item_Id;
         Slot : IR.Slot_Id;
         Block : IR.Block_Id;
         Value : IR.Value_Id;
         Site : constant Landin.Provenance.Origin :=
           (Source => 1, Where => Landin.Source.Empty_Span);
      begin
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Routine := IR.Add_Item
           (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
         Slot := IR.Add_Array_Slot
           (Unit, Routine, Landin.Types.U32, 3, IR.No_Declaration, Site);
         Block := IR.Add_Block
           (Unit, Routine, Landin.Resolution.Program_Scope, Site);
         IR.Enter (Unit, Routine, Block);
         Value := IR.Emit_Number
           (Unit, Routine, Landin.Types.U32, 1, False, Site);
         IR.Emit_Store_Slot_Field (Unit, Routine, Slot, 1, Value, Site);
         Value := IR.Emit_Number
           (Unit, Routine, Landin.Types.U32, 3, False, Site);
         IR.Emit_Store_Slot_Field (Unit, Routine, Slot, 3, Value, Site);
         IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
         IR.Leave_Block (Unit, Routine);

         declare
            Layout : constant Landin.Backend.Frame :=
              Landin.Backend.Laid_Out
                (Unit, Routine, Landin.Targets.Linux_X86_64);
            Text : constant String :=
              Landin.Backend.X86_64.Text
                (Unit, Landin.Stages.Meanings (Work).all,
                 Landin.Stages.Identities (Work).all,
                 Landin.Targets.Linux_X86_64);
         begin
            Landin.Testing.Check
              (Item,
               Landin.Backend.Slot_Offset (Layout, Slot) = 12
               and then Landin.Backend.Field_Offset
                          (Unit, Routine, Layout, Slot, 3,
                           Landin.Targets.Linux_X86_64) = 4,
               "generic layout reserves one cell and scales its parts");
            Landin.Testing.Check
              (Item, Contains (Text, HT & "movl %eax, -12(%rbp)"),
               "the first element starts at the bottom of the array cell");
            Landin.Testing.Check
              (Item, Contains (Text, HT & "movl %eax, -4(%rbp)"),
               "a constant index is scaled inside the same array cell");
         end;
      end;
   end Constant_Array_Parts_Address_One_Frame_Cell;

   --  D20's whole-array assignment remains one compact IR operation, so the
   --  backend forms one address for each endpoint rather than visiting its
   --  elements.  `usize` makes the byte count come from the target: three
   --  elements occupy twenty-four bytes on Linux x86-64 and twelve on the
   --  synthetic 32-bit description.  Even exact self-copy keeps the specified
   --  operation, with the same frame address in both string registers.
   procedure An_Array_Copy_Moves_A_Constant_Target_Extent
     (Item : in out Landin.Testing.Context);

   procedure An_Array_Copy_Moves_A_Constant_Target_Extent
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "mut source: [3]usize" & LF
        & "mut destination: [3]usize" & LF
        & "copy: () -> none =" & LF
        & "    mut local: [3]usize" & LF
        & "    local = source" & LF
        & "    destination = local" & LF
        & "    local = local" & LF
        & "end copy" & LF;

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Bytes : String);

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Bytes : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran  : Natural;
      begin
         Lower (Work, Source_Text, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         Landin.Testing.Check
           (Item, not Landin.Stages.Failed (Work), "the copies are accepted");

         declare
            Text : constant String := Emitted (Work);
            Move : constant String :=
              HT & "movabsq $" & Bytes & ", %rcx" & LF
              & HT & "cld" & LF
              & HT & "rep movsb" & LF;
            Local : constant String := "-" & Bytes & "(%rbp)";
         begin
            Landin.Testing.Check
              (Item,
               Contains
                 (Text,
                  HT & "leaq " & Local & ", %rdi" & LF
                  & HT & "leaq source(%rip), %rsi" & LF
                  & Move),
               "a module-to-local copy forms two compact addresses");
            Landin.Testing.Check
              (Item,
               Contains
                 (Text,
                  HT & "leaq destination(%rip), %rdi" & LF
                  & HT & "leaq " & Local & ", %rsi" & LF
                  & Move),
               "a local-to-module copy forms two compact addresses");
            Landin.Testing.Check
              (Item,
               Contains
                 (Text,
                  HT & "leaq " & Local & ", %rdi" & LF
                  & HT & "leaq " & Local & ", %rsi" & LF
                  & Move),
               "an exact self-copy names the same address at both endpoints");
            Landin.Testing.Check_Equal
              (Item, Occurrences (Text, Move), 3,
               "each fixed-size copy is one forward rep movsb operation");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, "24");
      Check_Target (Landin.Targets.Synthetic_32, "12");
   end An_Array_Copy_Moves_A_Constant_Target_Extent;

   --  D28 clears one complete compact array slot.  Its byte count follows
   --  the target's usize width and the emitted operation never visits source
   --  elements in the compiler.
   procedure A_Local_Array_Clear_Follows_The_Target_Extent
     (Item : in out Landin.Testing.Context);

   procedure A_Local_Array_Clear_Follows_The_Target_Extent
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "f: () -> none =" & LF
        & "    row: [3]usize = zeroed" & LF
        & "end f" & LF;

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Bytes : String);

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Bytes : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran  : Natural;
      begin
         Lower (Work, Source_Text, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

         declare
            Text : constant String := Emitted (Work);
            Clear : constant String :=
              HT & "leaq -" & Bytes & "(%rbp), %rdi" & LF
              & HT & "xorl %eax, %eax" & LF
              & HT & "movabsq $" & Bytes & ", %rcx" & LF
              & HT & "cld" & LF
              & HT & "rep stosb" & LF;
         begin
            Landin.Testing.Check
              (Item, Contains (Text, Clear),
               "one target-sized byte clear reaches the compact frame slot");
            Landin.Testing.Check_Equal
              (Item, Occurrences (Text, HT & "rep stosb" & LF), 1,
               "the complete array is cleared by one string operation");
            Landin.Testing.Check
              (Item, not Contains (Text, HT & "rep movsb" & LF),
               "zeroed does not invent a source array to copy");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, "24");
      Check_Target (Landin.Targets.Synthetic_32, "12");
   end A_Local_Array_Clear_Follows_The_Target_Extent;

   --  D30 reaches module array storage with the same target-sized byte clear,
   --  addressing the datum directly rather than inventing source storage.
   procedure A_Module_Array_Clear_Follows_The_Target_Extent
     (Item : in out Landin.Testing.Context);

   procedure A_Module_Array_Clear_Follows_The_Target_Extent
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "mut state: [3]usize" & LF
        & "f: () -> none =" & LF
        & "    state = zeroed" & LF
        & "end f" & LF;

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Bytes : String);

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Bytes : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran  : Natural;
      begin
         Lower (Work, Source_Text, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

         declare
            Text : constant String := Emitted (Work);
            Clear : constant String :=
              HT & "leaq state(%rip), %rdi" & LF
              & HT & "xorl %eax, %eax" & LF
              & HT & "movabsq $" & Bytes & ", %rcx" & LF
              & HT & "cld" & LF
              & HT & "rep stosb" & LF;
         begin
            Landin.Testing.Check
              (Item, Contains (Text, Clear),
               "one target-sized byte clear reaches the module datum");
            Landin.Testing.Check_Equal
              (Item, Occurrences (Text, HT & "rep stosb" & LF), 1,
               "the module array is cleared by one string operation");
            Landin.Testing.Check
              (Item, not Contains (Text, HT & "rep movsb" & LF),
               "zeroed assignment has no source array to copy");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, "24");
      Check_Target (Landin.Targets.Synthetic_32, "12");
   end A_Module_Array_Clear_Follows_The_Target_Extent;

   --  D58 reaches D57's whole aggregate clear through module storage.  The
   --  byte count is the target's padded object extent, not the sum of its
   --  field bytes, and the datum itself is the field-zero base address.
   procedure A_Module_Struct_Clear_Follows_The_Target_Extent
     (Item : in out Landin.Testing.Context);

   procedure A_Module_Struct_Clear_Follows_The_Target_Extent
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "holder: type = struct" & LF
        & "    tag: u8" & LF
        & "    row: [2]usize" & LF
        & "    tail: u16" & LF
        & "end holder" & LF
        & "mut state: holder" & LF
        & "f: () -> none =" & LF
        & "    state = zeroed" & LF
        & "end f" & LF;

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Bytes : String);

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Bytes : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran  : Natural;
      begin
         Lower (Work, Source_Text, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

         declare
            Text : constant String := Emitted (Work);
            Clear : constant String :=
              HT & "leaq state(%rip), %rdi" & LF
              & HT & "xorl %eax, %eax" & LF
              & HT & "movabsq $" & Bytes & ", %rcx" & LF
              & HT & "cld" & LF
              & HT & "rep stosb" & LF;
         begin
            Landin.Testing.Check
              (Item, Contains (Text, Clear),
               "one padded target extent is cleared at the module datum");
            Landin.Testing.Check_Equal
              (Item, Occurrences (Text, HT & "rep stosb" & LF), 1,
               "the whole struct image is one string operation");
            Landin.Testing.Check
              (Item, not Contains (Text, HT & "rep movsb" & LF),
               "zeroed assignment invents no aggregate source storage");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, "32");
      Check_Target (Landin.Targets.Synthetic_32, "16");
   end A_Module_Struct_Clear_Follows_The_Target_Extent;

   --  D87 recursively places D86's child run inside runtime storage.  The
   --  clear count is the parent's complete padded extent on each target,
   --  not the child's raw field-byte sum and not a host-derived constant.
   procedure A_Nested_Struct_Clear_Follows_The_Target_Extent
     (Item : in out Landin.Testing.Context);

   procedure A_Nested_Struct_Clear_Follows_The_Target_Extent
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "inner: type = struct" & LF
        & "    byte: u8" & LF
        & "    word: usize" & LF
        & "    row: [3]u16" & LF
        & "end inner" & LF
        & "outer: type = struct" & LF
        & "    prefix: u16" & LF
        & "    nested: inner" & LF
        & "    tail: u8" & LF
        & "end outer" & LF
        & "mut state: outer" & LF
        & "f: () -> none =" & LF
        & "    state = zeroed" & LF
        & "end f" & LF;

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Bytes : String);

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Bytes : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran  : Natural;
      begin
         Lower (Work, Source_Text, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

         declare
            Text : constant String := Emitted (Work);
            Clear : constant String :=
              HT & "leaq state(%rip), %rdi" & LF
              & HT & "xorl %eax, %eax" & LF
              & HT & "movabsq $" & Bytes & ", %rcx" & LF
              & HT & "cld" & LF
              & HT & "rep stosb" & LF;
         begin
            Landin.Testing.Check
              (Item, Contains (Text, Clear),
               "one recursively placed extent is cleared at the datum");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, "40");
      Check_Target (Landin.Targets.Synthetic_32, "24");
   end A_Nested_Struct_Clear_Follows_The_Target_Extent;

   --  D91 clears one ordinary child at its own recursively derived target
   --  extent, not the parent's extent and not the child's raw field sum.
   procedure An_Ordinary_Child_Clear_Follows_The_Target
     (Item : in out Landin.Testing.Context);

   procedure An_Ordinary_Child_Clear_Follows_The_Target
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "inner: type = struct" & LF
        & "    lead: u8" & LF
        & "    word: usize" & LF
        & "    row: [2]i32" & LF
        & "end inner" & LF
        & "outer: type = struct" & LF
        & "    prefix: u16" & LF
        & "    nested: inner" & LF
        & "    tail: u8" & LF
        & "end outer" & LF
        & "mut state: outer = zeroed" & LF
        & "f: () -> none =" & LF
        & "    state.nested = zeroed" & LF
        & "end f" & LF;

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Offset, Bytes : String);

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Offset, Bytes : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran : Natural;
      begin
         Lower (Work, Source_Text, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
            Clear : constant String :=
              HT & "leaq state(%rip), %rdi" & LF
              & HT & "movabsq $" & Offset & ", %rdx" & LF
              & HT & "addq %rdx, %rdi" & LF
              & HT & "xorl %eax, %eax" & LF
              & HT & "movabsq $" & Bytes & ", %rcx" & LF
              & HT & "cld" & LF
              & HT & "rep stosb" & LF;
         begin
            Landin.Testing.Check
              (Item, Contains (Text, Clear),
               "the clear uses the child offset and padded extent");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, "8", "24");
      Check_Target (Landin.Targets.Synthetic_32, "4", "16");
   end An_Ordinary_Child_Clear_Follows_The_Target;

   --  D88 replays both neutral field identities only after a target is
   --  selected.  Pointer width changes the padding before both the child and
   --  its `usize` leaf, so the same source reaches a different byte offset.
   procedure A_Nested_Scalar_Field_Follows_The_Target
     (Item : in out Landin.Testing.Context);

   procedure A_Nested_Scalar_Field_Follows_The_Target
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "inner: type = struct" & LF
        & "    byte: u8" & LF
        & "    word: usize" & LF
        & "end inner" & LF
        & "outer: type = struct" & LF
        & "    prefix: u16" & LF
        & "    nested: inner" & LF
        & "end outer" & LF
        & "mut state: outer = zeroed" & LF
        & "f: () -> (r: usize) =" & LF
        & "    state.nested.word = 7" & LF
        & "    r = state.nested.word" & LF
        & "end f" & LF;

      procedure Check_Target
        (Facts  : Landin.Targets.Target_Facts;
         Offset : String;
         Suffix : String);

      procedure Check_Target
        (Facts  : Landin.Targets.Target_Facts;
         Offset : String;
         Suffix : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran : Natural;
      begin
         Lower (Work, Source_Text, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
            Address : constant String :=
              HT & "leaq state(%rip), %rcx" & LF
              & HT & "movabsq $" & Offset & ", %rdx" & LF
              & HT & "addq %rdx, %rcx" & LF;
         begin
            Landin.Testing.Check
              (Item,
               Occurrences (Text, Address) = 2
                 and then Contains
                   (Text, HT & "mov" & Suffix & " %"
                    & (if Suffix = "q" then "rax" else "eax")
                    & ", (%rcx)")
                 and then Contains
                   (Text, HT & "mov" & Suffix & " (%rcx), %"
                    & (if Suffix = "q" then "rax" else "eax")),
               "the nested leaf is loaded and stored at its target offset");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, "16", "q");
      Check_Target (Landin.Targets.Synthetic_32, "8", "l");
   end A_Nested_Scalar_Field_Follows_The_Target;

   --  D89 places the parent child and then its compact fixed-array leaf.
   --  Both offsets change with pointer width while the two IR identities do
   --  not, and the computed element is added only after both placements.
   procedure A_Nested_Array_Element_Follows_The_Target
     (Item : in out Landin.Testing.Context);

   procedure A_Nested_Array_Element_Follows_The_Target
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "inner: type = struct" & LF
        & "    lead: u8" & LF
        & "    word: usize" & LF
        & "    row: [3]i32" & LF
        & "end inner" & LF
        & "outer: type = struct" & LF
        & "    prefix: u16" & LF
        & "    nested: inner" & LF
        & "end outer" & LF
        & "mut state: outer = zeroed" & LF
        & "f: (index: usize) -> (r: i32) =" & LF
        & "    state.nested.row[index] = 7" & LF
        & "    r = state.nested.row[index]" & LF
        & "end f" & LF;

      procedure Check_Target
        (Facts        : Landin.Targets.Target_Facts;
         Parent, Leaf : String);

      procedure Check_Target
        (Facts        : Landin.Targets.Target_Facts;
         Parent, Leaf : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran : Natural;
      begin
         Lower (Work, Source_Text, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
            Address : constant String :=
              HT & "leaq state(%rip), %rcx" & LF
              & HT & "movabsq $" & Parent & ", %rdx" & LF
              & HT & "addq %rdx, %rcx" & LF
              & HT & "movabsq $" & Leaf & ", %rdx" & LF
              & HT & "addq %rdx, %rcx" & LF
              & HT & "addq %rax, %rcx" & LF;
         begin
            Landin.Testing.Check_Equal
              (Item, Occurrences (Text, Address), 2,
               "both element operations replay both target offsets");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, "8", "16");
      Check_Target (Landin.Targets.Synthetic_32, "4", "8");
   end A_Nested_Array_Element_Follows_The_Target;

   --  D90 replays both endpoint paths for compact fills, copies and clears.
   --  Their extent remains the nested array's scalar bytes, never the
   --  containing child or parent extent.
   procedure Nested_Array_Values_Follow_The_Target
     (Item : in out Landin.Testing.Context);

   procedure Nested_Array_Values_Follow_The_Target
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "inner: type = struct" & LF
        & "    lead: u8" & LF
        & "    word: usize" & LF
        & "    row: [3]i32" & LF
        & "end inner" & LF
        & "outer: type = struct" & LF
        & "    prefix: u16" & LF
        & "    nested: inner" & LF
        & "end outer" & LF
        & "mut left: outer = zeroed" & LF
        & "mut right: outer = zeroed" & LF
        & "f: () -> none =" & LF
        & "    left.nested.row = [of 7]" & LF
        & "    right.nested.row = left.nested.row" & LF
        & "    left.nested.row = zeroed" & LF
        & "end f" & LF;

      procedure Check_Target
        (Facts        : Landin.Targets.Target_Facts;
         Parent, Leaf : String);

      procedure Check_Target
        (Facts        : Landin.Targets.Target_Facts;
         Parent, Leaf : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran : Natural;

         function Address (Name, Register : String) return String
         is (HT & "leaq " & Name & "(%rip), " & Register & LF
             & HT & "movabsq $" & Parent & ", %rdx" & LF
             & HT & "addq %rdx, " & Register & LF
             & HT & "movabsq $" & Leaf & ", %rdx" & LF
             & HT & "addq %rdx, " & Register & LF);
      begin
         Lower (Work, Source_Text, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item,
               Occurrences (Text, Address ("left", "%rdi")) = 2
                 and then Occurrences
                   (Text, Address ("right", "%rdi")) = 1
                 and then Occurrences
                   (Text, Address ("left", "%rsi")) = 1,
               "fill copy and clear replay both target offsets");
            Landin.Testing.Check
              (Item,
               Occurrences (Text, HT & "movabsq $12, %rcx" & LF) = 2
                 and then Occurrences
                   (Text, HT & "movabsq $3, %rcx" & LF) = 1,
               "byte copies and element fills use the nested array extent");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, "8", "16");
      Check_Target (Landin.Targets.Synthetic_32, "4", "8");
   end Nested_Array_Values_Follow_The_Target;

   --  D32 repeats an element count rather than a byte count, and selects the
   --  repeated-store width from the target's scalar facts.  `usize` therefore
   --  uses qwords on Linux x86-64 and longwords under Synthetic_32 while the
   --  same compact source fills both a frame slot and a module datum.
   procedure An_Array_Fill_Follows_The_Target_Element_Width
     (Item : in out Landin.Testing.Context);

   procedure An_Array_Fill_Follows_The_Target_Element_Width
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "mut state: [3]usize" & LF
        & "f: () -> none =" & LF
        & "    local: [3]usize = [3 of 7]" & LF
        & "    mixed: [4]usize = [1, 2, of 9]" & LF
        & "    state = [of 8]" & LF
        & "end f" & LF;

      procedure Check_Target
        (Facts  : Landin.Targets.Target_Facts;
         Bytes  : String;
         Offset : String;
         Suffix : String);

      procedure Check_Target
        (Facts  : Landin.Targets.Target_Facts;
         Bytes  : String;
         Offset : String;
         Suffix : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran  : Natural;
      begin
         Lower (Work, Source_Text, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
         Landin.Testing.Check
           (Item, not Landin.Stages.Failed (Work), "both fills are accepted");

         declare
            Text : constant String := Emitted (Work);
            Fill : constant String :=
              HT & "movabsq $3, %rcx" & LF
              & HT & "cld" & LF
              & HT & "rep stos" & Suffix & LF;
            Suffix_Offset : constant String :=
              HT & "addq $" & Offset & ", %rdi" & LF;
            Suffix_Count : constant String :=
              HT & "movabsq $2, %rcx" & LF
              & HT & "cld" & LF
              & HT & "rep stos" & Suffix & LF;
         begin
            Landin.Testing.Check
              (Item, Contains (Text, HT & "leaq -" & Bytes & "(%rbp), %rdi"),
               "the local fill reaches one target-sized array slot");
            Landin.Testing.Check
              (Item, Contains (Text, HT & "leaq state(%rip), %rdi"),
               "the assignment fill reaches module storage");
            Landin.Testing.Check_Equal
              (Item, Occurrences (Text, Fill), 2,
               "both full fills repeat three elements at the target width");
            Landin.Testing.Check
              (Item, Contains (Text, Suffix_Offset)
                     and then Contains (Text, Suffix_Count),
               "the suffix fill offsets past its prefix and repeats two");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, "24", "16", "q");
      Check_Target (Landin.Targets.Synthetic_32, "12", "8", "l");
   end An_Array_Fill_Follows_The_Target_Element_Width;

   --  D10 zeroes a module binding with no value, and zero bytes do not
   --  have to be in the image to be zero: `.bss` reserves them and `.data`
   --  carries them.  A 32 KB part is in this compiler's range, so a
   --  zeroed buffer must not be paid for twice, once in flash and once in
   --  RAM.  A value that is not zero has to be written down, so it stays.
   procedure Zero_Data_Is_Reserved_And_Not_Written
     (Item : in out Landin.Testing.Context);

   procedure Zero_Data_Is_Reserved_And_Not_Written
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "counters: type = struct" & LF
         & "    hits: u32" & LF
         & "    ready: bool" & LF
         & "end counters" & LF
         & "public mut state: counters" & LF
         & "mut counter: u32" & LF
         & "public answer: i32 = 42" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Contains (Text,
                      HT & ".globl state" & LF
                      & HT & ".type state, @object" & LF
                      & HT & ".align 4" & LF
                      & "state:" & LF
                      & HT & ".zero 8" & LF
                      & HT & ".size state, 8" & LF),
            "a zeroed struct is reserved whole");
         Landin.Testing.Check
           (Item,
            Contains (Text,
                      "counter:" & LF
                      & HT & ".zero 4" & LF),
            "and so is a zeroed scalar, rather than being written as 0");
         Landin.Testing.Check
           (Item,
            Contains (Text,
                      "answer:" & LF
                      & HT & ".long 42" & LF),
            "a value that is not zero is still written down");

         --  The sections are one run each, so each directive is written
         --  once however many objects it holds.
         Landin.Testing.Check_Equal
           (Item, Occurrences (Text, HT & ".bss" & LF), 1,
            "the reserved section is opened once");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Text, HT & ".data" & LF), 1,
            "and the written one is too");
         Landin.Testing.Check
           (Item,
            Index (Text, HT & ".data" & LF) < Index (Text, HT & ".bss" & LF),
            "written data comes before reserved, so each stays one run");
      end;
   end Zero_Data_Is_Reserved_And_Not_Written;

   --  D39 reaches the same absent loader-zero image as D10, including through
   --  a scalar alias: spelling `zeroed` must not move either datum to `.data`.
   procedure A_Zeroed_Module_Scalar_Stays_In_Bss
     (Item : in out Landin.Testing.Context);

   procedure A_Zeroed_Module_Scalar_Stays_In_Bss
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "word: type = u64" & LF
         & "number: word = zeroed" & LF
         & "flag: bool = zeroed" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Contains (Text, "number:" & LF & HT & ".zero 8" & LF),
            "the aliased integer zero is reserved");
         Landin.Testing.Check
           (Item,
            Contains (Text, "flag:" & LF & HT & ".zero 1" & LF),
            "false is reserved");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Text, HT & ".bss" & LF), 1,
            "both contextual zeros share the reserved section");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & ".data" & LF),
            "no written data image is emitted");
      end;
   end A_Zeroed_Module_Scalar_Stays_In_Bss;

   --  [1740]'s module state of [0520]'s array type.  D10 zeroes it, so it
   --  is reserved like any other zero, and its extent is the element
   --  repeated: `[4]u32` is sixteen bytes aligned to four, and `[3]usize`
   --  follows the target rather than the host.
   procedure An_Array_State_Is_Reserved_Whole
     (Item : in out Landin.Testing.Context);

   procedure An_Array_State_Is_Reserved_Whole
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "row: type = [4]u32" & LF
        & "public mut buffer: row" & LF
        & "mut copy: row = buffer" & LF
        & "mut inferred := copy" & LF
        & "mut wide: [3]usize" & LF;

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Wide  : String;
         Align : String);

      procedure Check_Target
        (Facts : Landin.Targets.Target_Facts;
         Wide  : String;
         Align : String)
      is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran  : Natural;
      begin
         Lower (Work, Source_Text, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

         declare
            Text : constant String := Emitted (Work);
         begin
            Landin.Testing.Check
              (Item,
               Contains (Text,
                         HT & ".globl buffer" & LF
                         & HT & ".type buffer, @object" & LF
                         & HT & ".align 4" & LF
                         & "buffer:" & LF
                         & HT & ".zero 16" & LF
                         & HT & ".size buffer, 16" & LF),
               "four u32 are sixteen bytes reserved whole");
            Landin.Testing.Check
              (Item,
               Contains (Text,
                         HT & ".align 4" & LF
                         & "copy:" & LF
                         & HT & ".zero 16" & LF
                         & HT & ".size copy, 16" & LF)
               and then Contains (Text,
                                  HT & ".align 4" & LF
                                  & "inferred:" & LF
                                  & HT & ".zero 16" & LF
                                  & HT & ".size inferred, 16" & LF),
               "typed and inferred images keep distinct zero storage");
            Landin.Testing.Check
              (Item,
               Contains (Text,
                         HT & ".align " & Align & LF
                         & "wide:" & LF
                         & HT & ".zero " & Wide & LF),
               "and a pointer-width element follows the target");
            Landin.Testing.Check
              (Item, Contains (Text, HT & ".bss" & LF),
               "a zeroed array is reserved and not written");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, "24", "8");
      Check_Target (Landin.Targets.Synthetic_32, "12", "4");
   end An_Array_State_Is_Reserved_Whole;

   --  D24: an array datum whose value is a literal reaches `.data` with
   --  one directive per element at the element's own alignment, while a
   --  chain terminating at D10 zero stays in `.bss` beside the other
   --  reserved storage, as does D27's explicitly `zeroed` array.  The four
   --  u32 image is sixteen bytes at four-byte alignment, and each position
   --  is spelled with its folded value.
   procedure A_Module_Array_Literal_Becomes_Data_Image
     (Item : in out Landin.Testing.Context);

   procedure A_Module_Array_Literal_Becomes_Data_Image
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "mut numbers: [4]u32 = [10, 20 + 1, base, base + 100]" & LF
         & "base: u32 = 100" & LF
         & "mut reserved: [2]u16" & LF
         & "mut cleared: [3]bool = zeroed" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Contains
              (Text,
               HT & ".data" & LF),
            "one .data section holds the images");
         Landin.Testing.Check
           (Item,
            Contains
              (Text,
               HT & ".type numbers, @object" & LF
               & HT & ".align 4" & LF
               & "numbers:" & LF
               & HT & ".long 10" & LF
               & HT & ".long 21" & LF
               & HT & ".long 100" & LF
               & HT & ".long 200" & LF
               & HT & ".size numbers, 16" & LF),
            "the array image is one directive per source-order element");
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & ".bss" & LF)
              and then Contains
                         (Text,
                          "reserved:" & LF
                          & HT & ".zero 4" & LF),
            "an omitted-initializer array stays reserved storage");
         Landin.Testing.Check
           (Item,
            Contains
              (Text,
               "cleared:" & LF
               & HT & ".zero 3" & LF),
            "an explicitly zeroed array stays reserved storage");
         Landin.Testing.Check
           (Item,
            Index (Text, HT & ".data" & LF)
              < Index (Text, HT & ".bss" & LF),
            "written data comes before reserved");
      end;
   end A_Module_Array_Literal_Becomes_Data_Image;

   --  D34: a nonzero repeated image is emitted as a constant number of
   --  directives for every scalar width.  In particular, the eight-byte
   --  pattern must not travel through GNU `.fill`'s four-byte value field.
   procedure Module_Repetition_Uses_Compact_Full_Width_Directives
     (Item : in out Landin.Testing.Context);

   procedure Module_Repetition_Uses_Compact_Full_Width_Directives
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "mut bytes: [3]u8 = [of 165]" & LF
         & "mut words: [4]u16 = [of 4660]" & LF
         & "mut longs: [5]u32 = [of 305419896]" & LF
         & "mut quads: [6]u64 = [of 0x123456789ABCDEF0]" & LF
         & "mut huge: [4294967295]u8 = [of 1]" & LF
         & "mut zero: [7]u64 = [of 0]" & LF
         & "mut hybrid: [4294967295]u8 = [1, 2, of 3]" & LF
         & "mut hybrid_zero: [4]u32 = [7, of 0]" & LF
         & "mut hybrid_quad: [4]u64 = [0x123456789ABCDEF0,"
         & " of 0xFEDCBA9876543210]" & LF
         & "mut hybrid_through: [4]u64 = hybrid_quad" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Contains (Text, "bytes:" & LF & HT & ".rept 3" & LF
                            & HT & ".byte 165" & LF & HT & ".endr" & LF)
            and then Contains
              (Text, "words:" & LF & HT & ".rept 4" & LF
                     & HT & ".word 4660" & LF & HT & ".endr" & LF)
            and then Contains
              (Text, "longs:" & LF & HT & ".rept 5" & LF
                     & HT & ".long 305419896" & LF & HT & ".endr" & LF),
            "one repeated directive preserves each one-to-four-byte pattern");
         Landin.Testing.Check
           (Item,
            Contains
              (Text, "quads:" & LF & HT & ".rept 6" & LF
                     & HT & ".quad 1311768467463790320" & LF
                     & HT & ".endr" & LF),
            "the repeated quad carries all eight bytes without .fill");
         Landin.Testing.Check
           (Item,
            Contains
              (Text, "huge:" & LF & HT & ".rept 4294967295" & LF
                     & HT & ".byte 1" & LF & HT & ".endr" & LF),
            "a target-sized extent does not enlarge the assembly text");
         Landin.Testing.Check
           (Item,
            Contains
              (Text, "hybrid:" & LF & HT & ".byte 1" & LF
                     & HT & ".byte 2" & LF
                     & HT & ".rept 4294967293" & LF
                     & HT & ".byte 3" & LF & HT & ".endr" & LF),
            "a target-sized hybrid emits its prefix and one compact suffix");
         Landin.Testing.Check
           (Item,
            Contains
              (Text, "hybrid_zero:" & LF & HT & ".long 7" & LF
                     & HT & ".rept 3" & LF & HT & ".long 0" & LF
                     & HT & ".endr" & LF),
            "a zero suffix remains a present data image");
         Landin.Testing.Check
           (Item,
            Contains
              (Text, "hybrid_quad:" & LF
                     & HT & ".quad 1311768467463790320" & LF
                     & HT & ".rept 3" & LF
                     & HT & ".quad 18364758544493064720" & LF
                     & HT & ".endr" & LF)
            and then Contains
              (Text, "hybrid_through:" & LF
                     & HT & ".quad 1311768467463790320" & LF
                     & HT & ".rept 3" & LF
                     & HT & ".quad 18364758544493064720" & LF
                     & HT & ".endr" & LF),
            "hybrid chains preserve every byte of 64-bit prefix and suffix");
         Landin.Testing.Check
           (Item,
            Contains (Text, "zero:" & LF & HT & ".zero 56" & LF),
            "a zero-pattern repetition remains reserved storage");
      end;
   end Module_Repetition_Uses_Compact_Full_Width_Directives;

   --  [0520]'s element, reached by an index the compiler knows.  It sits
   --  where the element size puts it, so `[4]u32` reads its third at four
   --  bytes times two, and a `[8]bool` reads its fifth one byte along at
   --  a time -- which is what says the offset is the element's and not a
   --  number this backend invented.
   procedure An_Element_Is_Read_At_Its_Own_Offset
     (Item : in out Landin.Testing.Context);

   procedure An_Element_Is_Read_At_Its_Own_Offset
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "mut words: [4]u32" & LF
         & "mut flags: [8]bool" & LF
         & "mut far: [2147483649]u8" & LF
         & "use: () -> none =" & LF
         & "    a: u32 = words[0]" & LF
         & "    b: u32 = words[2]" & LF
         & "    c: bool = flags[5]" & LF
         & "    d: u8 = far[2147483648]" & LF
         & "    words[3] = 7" & LF
         & "end use" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movl words(%rip), %eax"),
            "the first element needs no displacement");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movabsq $8, %rdx")
                  and then Contains (Text, HT & "movl (%rcx), %eax"),
            "the third is two elements along");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movabsq $5, %rdx")
                  and then Contains (Text, HT & "movb (%rcx), %al"),
            "and a one-byte element counts in ones");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movabsq $12, %rdx")
                  and then Contains (Text, HT & "movl %eax, (%rcx)"),
            "a written element reaches the same bytes");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "leaq far(%rip), %rcx"),
            "a displacement too wide for RIP-relative addressing starts"
            & " from the symbol");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movabsq $2147483648, %rdx")
                  and then Contains (Text, HT & "addq %rdx, %rcx")
                  and then Contains (Text, HT & "movb (%rcx), %al"),
            "and adds the full target offset in registers");
      end;
   end An_Element_Is_Read_At_Its_Own_Offset;

   --  [0580] makes bounds checking an ordering rule, not just a comparison:
   --  the unsigned index must be below the length before scaling it or
   --  forming an address.  Both a read and a write take that guarded path.
   procedure A_Computed_Element_Is_Checked_Before_Its_Address
     (Item : in out Landin.Testing.Context);

   procedure A_Computed_Element_Is_Checked_Before_Its_Address
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "mut words: [4]u32" & LF
         & "at: (i: usize) -> (r: u32) =" & LF
         & "    words[i] = 7" & LF
         & "    r = words[i]" & LF
         & "end at" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Compare : constant Natural := Index (Text, HT & "cmpq %rdx, %rax");
         Trap : constant Natural := Index (Text, HT & "ud2");
         Scale : constant Natural := Index (Text, HT & "imulq $4, %rax, %rax");
         Address : constant Natural :=
           Index (Text, HT & "leaq words(%rip), %rcx");
      begin
         Landin.Testing.Check
           (Item,
            Compare > 0 and then Compare < Trap
            and then Trap < Scale and then Scale < Address,
            "the unsigned bounds check and trap precede scaling and address");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Text, HT & "cmpq %rdx, %rax"), 2,
            "the store and load each check the runtime index");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Text, HT & "jb "), 2,
            "both checks use unsigned below");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Text, HT & "ud2"), 2,
            "both out-of-bounds paths trap deliberately");
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "movl %eax, (%rcx)")
            and then Contains (Text, HT & "movl (%rcx), %eax"),
            "the guarded addresses carry a u32 write and read");
      end;
   end A_Computed_Element_Is_Checked_Before_Its_Address;

   --  D22: a computed local array element traps like the module one and
   --  then reaches its own frame slot rather than a datum symbol.  The
   --  cell's `%rbp` displacement is where Landin.Backend already places
   --  the array's element zero.
   procedure A_Computed_Local_Element_Reaches_Its_Slot
     (Item : in out Landin.Testing.Context);

   procedure A_Computed_Local_Element_Reaches_Its_Slot
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "source: [4]u32" & LF
         & "at: (i: usize, value: u32) -> (r: u32) =" & LF
         & "    mut words: [4]u32" & LF
         & "    words = source" & LF
         & "    words[i] = value" & LF
         & "    r = words[i]" & LF
         & "end at" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Compare : constant Natural := Index (Text, HT & "cmpq %rdx, %rax");
         Trap : constant Natural := Index (Text, HT & "ud2");
         Scale : constant Natural :=
           Index (Text, HT & "imulq $4, %rax, %rax");
         --  The frame layout puts a [4]u32 slot at -32(%rbp) on this
         --  routine: eight bytes for the `at` parameter, then four for
         --  `value`, then the four-word array whose element zero sits
         --  furthest below the frame pointer.
         Address : constant Natural :=
           Index (Text, HT & "leaq -32(%rbp), %rcx");
      begin
         Landin.Testing.Check
           (Item,
            Compare > 0 and then Compare < Trap
            and then Trap < Scale and then Scale < Address,
            "the trap and scaling precede the frame-slot address");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Text, HT & "cmpq %rdx, %rax"), 2,
            "both the store and the load check the runtime index");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Text, HT & "ud2"), 2,
            "both out-of-bounds paths trap deliberately");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Text, HT & "leaq -32(%rbp), %rcx"), 2,
            "each element operation reaches the slot's own base");
         Landin.Testing.Check
           (Item,
            not Contains (Text, HT & "leaq words(%rip), %rcx"),
            "no datum symbol appears for the local array");
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "movl %eax, (%rcx)")
            and then Contains (Text, HT & "movl (%rcx), %eax"),
            "the guarded addresses carry a u32 write and read");
      end;
   end A_Computed_Local_Element_Reaches_Its_Slot;

   --  A module value is reached by name rather than through a frame, and
   --  x86-64's position-independent form of that name is RIP-relative.
   --  [1900] lets a `mut` module binding be written as well as read.
   procedure A_Module_Binding_Is_Reached_Through_Rip
     (Item : in out Landin.Testing.Context);

   procedure A_Module_Binding_Is_Reached_Through_Rip
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "mut counter: u32" & LF
         & "bump: () -> (r: u32) =" & LF
         & "    counter = counter + 1" & LF
         & "    r = counter" & LF & "end bump" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movl counter(%rip), %eax"),
            "a module value is read through RIP");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movl %eax, counter(%rip)"),
            "and written back the same way");
         Landin.Testing.Check
           (Item, Contains (Text, "counter:" & LF & HT & ".zero 4" & LF),
            "D10's binding with no value holds zero, reserved not written");
      end;
   end A_Module_Binding_Is_Reached_Through_Rip;

   --  [1940] folds an operator in a module value, and `Landin.IR`'s header
   --  says the checker leaves the bitwise and shift levels to whoever has a
   --  width.  That is this backend, so the fold finishes here.
   procedure A_Module_Value_Folds_Every_Level
     (Item : in out Landin.Testing.Context);

   procedure A_Module_Value_Folds_Every_Level
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "sum: i32 = 40 + 2" & LF
         & "derived: i32 = sum + 1" & LF
         & "beyond: u32 = 1 << 40" & LF
         & "masked: u8 = ~0 & 240" & LF
         & "below: i8 = 0 - 100" & LF
         & "verdict: bool = 3 > 2" & LF
         & "kept: i8 = below >> 7" & LF
         & "wide: i32 = sum - 298 >> 4" & LF
         & "carried: u16 = 40000 + 30000 - 10000" & LF
         & "halved: u16 = (40000 + 30000) / 2" & LF
         & "wrapped: u16 = 40000 +% 30000 -% 10000" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, "sum:" & LF & HT & ".long 42" & LF),
            "an arithmetic fold reaches its value");
         Landin.Testing.Check
           (Item, Contains (Text, "derived:" & LF & HT & ".long 43" & LF),
            "a module value may name one folded above it");
         --  Reserved rather than written, because the fold reached zero:
         --  what the case is about is the answer, not the section.
         Landin.Testing.Check
           (Item, Contains (Text, "beyond:" & LF & HT & ".zero 4" & LF),
            "D13's zero beyond the width holds at module level too");
         Landin.Testing.Check
           (Item, Contains (Text, "masked:" & LF & HT & ".byte 240" & LF),
            "a complement folds at its own width and not at 64");
         Landin.Testing.Check
           (Item, Contains (Text, "below:" & LF & HT & ".byte -100" & LF),
            "a negative fold is written as one");
         Landin.Testing.Check
           (Item, Contains (Text, "verdict:" & LF & HT & ".byte 1" & LF),
            "a comparison folds to [1870]'s one-byte bool");
         --  Every complement in an arithmetic shift is at the type's own
         --  width; taking one at the fold's 64 gives 127 here instead.
         Landin.Testing.Check
           (Item, Contains (Text, "kept:" & LF & HT & ".byte -1" & LF),
            "a negative shift right keeps the sign at its own width");
         Landin.Testing.Check
           (Item, Contains (Text, "wide:" & LF & HT & ".long -16" & LF),
            "and at a wider one");
         --  A checked operator has no width to answer at, because [1460]
         --  gives a module value no moment in which to trap: the whole
         --  expression is worked out and the checker refuses the answer no
         --  type holds.  Masking each step instead would give 2232 here.
         Landin.Testing.Check
           (Item, Contains (Text, "carried:" & LF & HT & ".word 60000" & LF),
            "a checked fold carries an intermediate no type holds");
         Landin.Testing.Check
           (Item, Contains (Text, "halved:" & LF & HT & ".word 35000" & LF),
            "and divides the number rather than a narrowed pattern");
         --  [0300]'s wrapping forms are about a width and say so, so these
         --  do narrow at each step: 70000 wraps to 4464 before the minus.
         Landin.Testing.Check
           (Item, Contains (Text, "wrapped:" & LF & HT & ".word 60000" & LF),
            "a wrapping fold narrows at each step");
      end;
   end A_Module_Value_Folds_Every_Level;

   --  R1.80's exit evidence asks for deterministic assembly, and until this
   --  case nothing held it to that.  Two runs of one source through two
   --  separate compilations must agree byte for byte: an address, a hash
   --  order or a clock reaching the text would show up here and nowhere
   --  else, since a single run agrees with itself by construction.
   procedure The_Same_Source_Emits_The_Same_Bytes
     (Item : in out Landin.Testing.Context);

   procedure The_Same_Source_Emits_The_Same_Bytes
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "counter: i32 = 7 + 1" & LF
        & "fib: (n: u32) -> (r: u32) =" & LF
        & "    r = n" & LF
        & "    if n > 1 then" & LF
        & "        r = fib(n - 1) + fib(n - 2)" & LF
        & "    end if" & LF
        & "end fib" & LF
        & "g: (a: i32, b: i32) -> (r: i32) =" & LF
        & "    r = a * b - counter" & LF
        & "end g" & LF;

      First  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Second : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran    : Natural;
   begin
      Lower (First, Source, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Lower (Second, Source, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, "and five again");

      Landin.Testing.Check_Equal
        (Item, Emitted (First), Emitted (Second),
         "one source emits one text");
   end The_Same_Source_Emits_The_Same_Bytes;

   --  D84 keeps the nested payload address target-neutral.  One source
   --  therefore derives both the element scale and the tag/payload padding
   --  again for each target description.
   procedure Variant_Array_Payload_Writes_Follow_The_Target
     (Item : in out Landin.Testing.Context);

   procedure Variant_Array_Payload_Writes_Follow_The_Target
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "tagged: type = struct" & LF
        & "    prefix: u8" & LF
        & "    kind: variant" & LF
        & "        empty |" & LF
        & "        arrays: (row: [3]usize)" & LF
        & "    end kind" & LF
        & "    tail: u8" & LF
        & "end tagged" & LF
        & "holder: type = struct" & LF
        & "    row: [3]usize" & LF
        & "end holder" & LF
        & "source: [3]usize = [11, 13, 17]" & LF
        & "selected: holder = (row: [19, 23, 29])" & LF
        & "mut state: tagged" & LF
        & "write: () -> none =" & LF
        & "    mut local: tagged = zeroed" & LF
        & "    state.kind = arrays(row: [31, 37, 41])" & LF
        & "    local.kind = arrays(row: [3 of 43])" & LF
        & "    state.kind = arrays(row: source)" & LF
        & "    local.kind = arrays(row: selected.row)" & LF
        & "end write" & LF;
      Native : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Narrow : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Synthetic_32);
      Ran : Natural;
   begin
      Lower (Native, Source, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Lower (Narrow, Source, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, "and five again");

      declare
         Wide : constant String := Emitted (Native);
         Thin : constant String :=
           Landin.Backend.X86_64.Text
             (Landin.Stages.Code (Narrow).all,
              Landin.Stages.Meanings (Narrow).all,
              Landin.Stages.Identities (Narrow).all,
              Landin.Targets.Synthetic_32);
      begin
         Landin.Testing.Check
           (Item,
            Contains (Wide, HT & "imulq $8, %rax, %rax")
              and then Contains (Thin, HT & "imulq $4, %rax, %rax"),
            "nested element stores use the target usize scale");
         Landin.Testing.Check
           (Item,
            Contains (Wide, HT & "rep stosq")
              and then Contains (Thin, HT & "rep stosl"),
            "nested repetition uses the target element directive");
         Landin.Testing.Check
           (Item,
            Contains (Wide, HT & "movabsq $24, %rcx")
              and then Contains (Thin, HT & "movabsq $12, %rcx"),
            "nested array copies derive the target byte extent");
         Landin.Testing.Check
           (Item,
            Occurrences (Wide, HT & "movabsq $8, %rdx") > 0
              and then Occurrences (Thin, HT & "movabsq $4, %rdx") > 0,
            "variant payload bases replay target tag and payload padding");
      end;
   end Variant_Array_Payload_Writes_Follow_The_Target;

   --  D14: a measurement is answered from the target description and
   --  nowhere else, which is the whole reason `Landin.IR` carries the type
   --  asked about rather than the answer.  One source, two descriptions,
   --  two answers -- and the host this runs on is neither of them.
   procedure A_Measurement_Follows_The_Target
     (Item : in out Landin.Testing.Context);

   procedure A_Measurement_Follows_The_Target
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "row: type = [3]usize" & LF
        & "packet: type = row" & LF
        & "here: usize = sizeof usize" & LF
        & "wide: usize = sizeof u32" & LF
        & "array_size: usize = sizeof packet" & LF
        & "array_align: usize = alignof [3]usize" & LF
        & "header: type = struct" & LF
        & "    tag: u8" & LF
        & "    address: usize" & LF
        & "    tail: u16" & LF
        & "end header" & LF
        & "header_alias: type = header" & LF
        & "struct_size: usize = sizeof header_alias" & LF
        & "struct_align: usize = alignof header" & LF
        & "nested: type = struct" & LF
        & "    tag: u8" & LF
        & "    words: [2]usize" & LF
        & "    tail: u16" & LF
        & "end nested" & LF
        & "nested_alias: type = nested" & LF
        & "nested_size: usize = sizeof nested_alias" & LF
        & "nested_align: usize = alignof nested" & LF
        & "tagged: type = struct" & LF
        & "    prefix: u8" & LF
        & "    kind: variant" & LF
        & "        no_payload |" & LF
        & "        wide_payload: (word: usize, byte: u8) |" & LF
        & "        array_payload: (row: [3]u16)" & LF
        & "    end kind" & LF
        & "    tail: u16" & LF
        & "end tagged" & LF
        & "mut variant_state: tagged" & LF
        & "variant_size: usize = sizeof tagged" & LF
        & "variant_align: usize = alignof tagged" & LF
        & "clear_variant: () -> none =" & LF
        & "    mut local: tagged = zeroed" & LF
        & "    mut copied: tagged = local" & LF
        & "    variant_state = copied" & LF
        & "    variant_state = zeroed" & LF
        & "    variant_state.kind = wide_payload(word: 7, byte: 9)" & LF
        & "    local.kind = array_payload(row: zeroed)" & LF
        & "    match variant_state.kind" & LF
        & "        no_payload: _ = 1" & LF
        & "        wide_payload: _ = 2" & LF
        & "        array_payload: _ = 3" & LF
        & "    end match" & LF
        & "    match local.kind" & LF
        & "        no_payload: _ = 1" & LF
        & "        wide_payload: _ = 2" & LF
        & "        array_payload: _ = 3" & LF
        & "    end match" & LF
        & "end clear_variant" & LF;

      Native : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Narrow : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Synthetic_32);
      Ran    : Natural;
   begin
      Lower (Native, Source, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Lower (Narrow, Source, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, "and five again");

      declare
         Wide : constant String := Emitted (Native);
         Thin : constant String :=
           Landin.Backend.X86_64.Text
             (Landin.Stages.Code (Narrow).all,
              Landin.Stages.Meanings (Narrow).all,
              Landin.Stages.Identities (Narrow).all,
              Landin.Targets.Synthetic_32);
      begin
         Landin.Testing.Check
           (Item, Contains (Wide, "here:" & LF & HT & ".quad 8" & LF),
            "usize is eight bytes on the 64-bit description");
         Landin.Testing.Check
           (Item, Contains (Thin, "here:" & LF & HT & ".long 4" & LF),
            "and four on the 32-bit one, from the same source");
         --  A type whose width no target argues about, so the difference
         --  above is the pointer width and not the whole model moving.
         Landin.Testing.Check
           (Item, Contains (Wide, "wide:" & LF & HT & ".quad 4" & LF)
                  and then Contains (Thin, "wide:" & LF & HT & ".long 4"
                                           & LF),
            "u32 is four bytes on both");
         Landin.Testing.Check
           (Item,
            Contains (Wide, "array_size:" & LF & HT & ".quad 24" & LF)
              and then Contains
                (Thin, "array_size:" & LF & HT & ".long 12" & LF),
            "an aliased array multiplies its target element size");
         Landin.Testing.Check
           (Item,
            Contains (Wide, "array_align:" & LF & HT & ".quad 8" & LF)
              and then Contains
                (Thin, "array_align:" & LF & HT & ".long 4" & LF),
            "an inline array keeps its target element alignment");
         Landin.Testing.Check
           (Item,
            Contains (Wide, "struct_size:" & LF & HT & ".quad 24" & LF)
              and then Contains
                (Thin, "struct_size:" & LF & HT & ".long 12" & LF),
            "an aliased struct derives padded size from target placement");
         Landin.Testing.Check
           (Item,
            Contains (Wide, "struct_align:" & LF & HT & ".quad 8" & LF)
              and then Contains
                (Thin, "struct_align:" & LF & HT & ".long 4" & LF),
            "a struct derives alignment from its target field run");
         Landin.Testing.Check
           (Item,
            Contains (Wide, "nested_size:" & LF & HT & ".quad 32" & LF)
              and then Contains
                (Thin, "nested_size:" & LF & HT & ".long 16" & LF),
            "a compact array field contributes its target-sized extent");
         Landin.Testing.Check
           (Item,
            Contains (Wide, "nested_align:" & LF & HT & ".quad 8" & LF)
              and then Contains
                (Thin, "nested_align:" & LF & HT & ".long 4" & LF),
            "an array field contributes its target element alignment");
         Landin.Testing.Check
           (Item,
            Contains (Wide, "variant_size:" & LF & HT & ".quad 40" & LF)
              and then Contains
                (Thin, "variant_size:" & LF & HT & ".long 20" & LF),
            "a variant reserves its target's maximum padded payload");
         Landin.Testing.Check
           (Item,
            Contains (Wide, "variant_align:" & LF & HT & ".quad 8" & LF)
              and then Contains
                (Thin, "variant_align:" & LF & HT & ".long 4" & LF),
            "a variant inherits the maximum target payload alignment");
         Landin.Testing.Check
           (Item,
            Contains
              (Wide, "variant_state:" & LF & HT & ".zero 40" & LF)
              and then Contains
                (Thin, "variant_state:" & LF & HT & ".zero 20" & LF),
            "variant-bearing module storage reserves its padded extent");
         Landin.Testing.Check
           (Item,
            Occurrences (Wide, HT & "movabsq $40, %rcx") = 2
              and then Occurrences (Thin, HT & "movabsq $20, %rcx") = 2
              and then Occurrences (Wide, HT & "rep stosb") = 4
              and then Occurrences (Thin, HT & "rep stosb") = 4,
            "module and local zero images clear one target-derived extent");
         Landin.Testing.Check
           (Item,
            Occurrences (Wide, HT & "movabsq $24, %rcx") = 4
              and then Occurrences (Thin, HT & "movabsq $12, %rcx") = 4
              and then Contains (Wide, HT & "movb $1, (%rcx)" & LF)
              and then Contains (Wide, HT & "movb $2, (%rcx)" & LF)
              and then Contains (Thin, HT & "movb $1, (%rcx)" & LF)
              and then Contains (Thin, HT & "movb $2, (%rcx)" & LF),
            "selection and copy use the target-derived variant extent");
         Landin.Testing.Check
           (Item,
            Occurrences (Wide, HT & "rep movsb") = 2
              and then Occurrences (Thin, HT & "rep movsb") = 2,
            "each whole copy moves one complete padded variant part");
         Landin.Testing.Check
           (Item,
            Occurrences (Wide, HT & "movb (%rcx), %al") = 2
              and then Occurrences (Thin, HT & "movb (%rcx), %al") = 2,
            "tag-only matches load the target-described u8 tag once");
         Landin.Testing.Check
           (Item,
            Contains (Wide, HT & "movabsq $8, %rdx" & LF)
              and then Contains (Wide, HT & "movabsq $16, %rdx" & LF)
              and then Contains (Thin, HT & "movabsq $4, %rdx" & LF)
              and then Contains (Thin, HT & "movabsq $8, %rdx" & LF),
            "payload stores replay each target's tag and field layout");
      end;
   end A_Measurement_Follows_The_Target;

   --  x86-64 divides its implicit full-width dividend.  An unknown zero
   --  divisor therefore reaches Landin's explicit trap before `div`, while a
   --  valid u8 dividend has its high byte cleared and stores the quotient.
   procedure Unsigned_Divide_Guards_Zero_And_Stores_The_Quotient
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_Divide_Guards_Zero_And_Stores_The_Quotient
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u8, b: u8) -> (r: u8) =" & LF
         & "    r = a / b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Guard : constant String :=
           HT & "cmpb $0, -6(%rbp)" & LF
           & HT & "jne .L1_V5_nonzero" & LF
           & HT & "ud2" & LF
           & ".L1_V5_nonzero:" & LF;
         Operation : constant String :=
           HT & "movb -7(%rbp), %al" & LF
           & HT & "movb $0, %ah" & LF
           & HT & "divb -6(%rbp)" & LF
           & HT & "movb %al, -8(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Guard),
            "a runtime zero divisor reaches an explicit trap");
         Landin.Testing.Check
           (Item, Contains (Text, Operation),
            "u8 division clears the high dividend and stores its quotient");
      end;
   end Unsigned_Divide_Guards_Zero_And_Stores_The_Quotient;

   --  Signed division has a second trap case: the minimum value divided by
   --  minus one.  It is recognized before `idiv`, rather than inheriting the
   --  processor's incidental divide fault, and a valid byte is sign-extended.
   procedure Signed_Divide_Guards_Overflow_And_Truncates
     (Item : in out Landin.Testing.Context);

   procedure Signed_Divide_Guards_Overflow_And_Truncates
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i8, b: i8) -> (r: i8) =" & LF
         & "    r = a / b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Overflow : constant String :=
           HT & "cmpb $-1, -6(%rbp)" & LF
           & HT & "jne .L1_V5_divide" & LF
           & HT & "movabsq $128, %rax" & LF
           & HT & "cmpb -7(%rbp), %al" & LF
           & HT & "jne .L1_V5_divide" & LF
           & HT & "ud2" & LF;
         Operation : constant String :=
           ".L1_V5_divide:" & LF
           & HT & "movb -7(%rbp), %al" & LF
           & HT & "cbtw" & LF
           & HT & "idivb -6(%rbp)" & LF
           & HT & "movb %al, -8(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Overflow),
            "signed minimum divided by minus one reaches an explicit trap");
         Landin.Testing.Check
           (Item, Contains (Text, Operation),
            "i8 division sign-extends its dividend and stores the quotient");
      end;
   end Signed_Divide_Guards_Overflow_And_Truncates;

   --  The signed minimum modulo minus one is zero in Landin.  Since `idiv`
   --  would fault for that operand pair, remainder recognizes it as a
   --  successful zero result and otherwise stores the high half's remainder.
   procedure Signed_Remainder_Handles_Minimum_Modulo_Minus_One
     (Item : in out Landin.Testing.Context);

   procedure Signed_Remainder_Handles_Minimum_Modulo_Minus_One
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i8, b: i8) -> (r: i8) =" & LF
         & "    r = a % b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Special : constant String :=
           HT & "cmpb $-1, -6(%rbp)" & LF
           & HT & "jne .L1_V5_divide" & LF
           & HT & "movabsq $128, %rax" & LF
           & HT & "cmpb -7(%rbp), %al" & LF
           & HT & "jne .L1_V5_divide" & LF
           & HT & "movb $0, -8(%rbp)" & LF
           & HT & "jmp .L1_V5_done" & LF;
         Operation : constant String :=
           ".L1_V5_divide:" & LF
           & HT & "movb -7(%rbp), %al" & LF
           & HT & "cbtw" & LF
           & HT & "idivb -6(%rbp)" & LF
           & HT & "movb %ah, -8(%rbp)" & LF
           & ".L1_V5_done:" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Special),
            "signed minimum modulo minus one stores zero without dividing");
         Landin.Testing.Check
           (Item, Contains (Text, Operation),
            "an ordinary i8 remainder comes from its implicit register");
      end;
   end Signed_Remainder_Handles_Minimum_Modulo_Minus_One;

   --  One-operand `mul` forms a full unsigned product in the implicit
   --  accumulator pair.  Carry is clear exactly when its high half is zero,
   --  so the successful edge alone may store the low byte.
   procedure Unsigned_Multiply_Uses_The_Full_Product
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_Multiply_Uses_The_Full_Product
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u8, b: u8) -> (r: u8) =" & LF
         & "    r = a * b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Operation : constant String :=
           HT & "movb -7(%rbp), %al" & LF
           & HT & "mulb -6(%rbp)" & LF
           & HT & "jnc .L1_V";
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Operation),
            "u8 multiply checks the full unsigned product immediately");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "ud2" & LF & ".L1_V"),
            "unsigned overflow reaches an explicit trap");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movb %al, -8(%rbp)"),
            "only the successful edge stores the low product");
      end;
   end Unsigned_Multiply_Uses_The_Full_Product;

   --  One-operand `imul` reports whether the full signed product is the sign
   --  extension of its low half.  Its overflow flag therefore decides whether
   --  the low byte is representable, independently of unsigned carry.
   procedure Signed_Multiply_Uses_Overflow_To_Trap
     (Item : in out Landin.Testing.Context);

   procedure Signed_Multiply_Uses_Overflow_To_Trap
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i8, b: i8) -> (r: i8) =" & LF
         & "    r = a * b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Operation : constant String :=
           HT & "movb -7(%rbp), %al" & LF
           & HT & "imulb -6(%rbp)" & LF
           & HT & "jno .L1_V";
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Operation),
            "i8 multiply tests signed overflow immediately");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "jnc .L1_V"),
            "signed multiply does not use unsigned carry");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "ud2" & LF & ".L1_V"),
            "signed overflow reaches an explicit trap");
      end;
   end Signed_Multiply_Uses_Overflow_To_Trap;

   --  [0300]'s wrapping multiply keeps the accumulator's low target-width
   --  half.  The full product may overflow, but no flag or trap edge is read.
   procedure Wrapping_Multiply_Keeps_The_Low_Product
     (Item : in out Landin.Testing.Context);

   procedure Wrapping_Multiply_Keeps_The_Low_Product
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: isize, b: isize) -> (r: isize) =" & LF
         & "    r = a *% b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movq -56(%rbp), %rax" & LF
           & HT & "imulq -48(%rbp)" & LF
           & HT & "movq %rax, -64(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "wrapping isize multiply stores the low target-width product");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "ud2"),
            "wrapping multiply has no trap edge");
      end;
   end Wrapping_Multiply_Keeps_The_Low_Product;

   --  [0300]'s wrapping add keeps the low byte and ignores carry.  With no
   --  checked operation in this routine, no trap edge belongs in its text.
   procedure Wrapping_Add_Ignores_Overflow
     (Item : in out Landin.Testing.Context);

   procedure Wrapping_Add_Ignores_Overflow
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u8, b: u8) -> (r: u8) =" & LF
         & "    r = a +% b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movb -7(%rbp), %al" & LF
           & HT & "addb -6(%rbp), %al" & LF
           & HT & "movb %al, -8(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "wrapping u8 addition stores the low byte immediately");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "ud2"),
            "wrapping addition has no trap edge");
      end;
   end Wrapping_Add_Ignores_Overflow;

   --  A target-width wrapping result follows the target rather than the host,
   --  and subtraction likewise stores immediately without inspecting flags.
   procedure Wrapping_Subtract_Follows_The_Target_Width
     (Item : in out Landin.Testing.Context);

   procedure Wrapping_Subtract_Follows_The_Target_Width
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: isize, b: isize) -> (r: isize) =" & LF
         & "    r = a -% b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movq -56(%rbp), %rax" & LF
           & HT & "subq -48(%rbp), %rax" & LF
           & HT & "movq %rax, -64(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "wrapping isize subtraction follows the target width");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "ud2"),
            "wrapping subtraction has no trap edge");
      end;
   end Wrapping_Subtract_Follows_The_Target_Width;

   --  AT&T's compare writes no destination, but its operand order still
   --  matters: `cmp right, left` sets flags for left minus right.  A signed
   --  less-than then materializes [1890]'s one-byte bool from those flags.
   procedure Signed_Less_Than_Compares_Left_With_Right
     (Item : in out Landin.Testing.Context);

   procedure Signed_Less_Than_Compares_Left_With_Right
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i32, b: i32) -> (r: bool) =" & LF
         & "    r = a < b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movl -28(%rbp), %eax" & LF
           & HT & "cmpl -24(%rbp), %eax" & LF
           & HT & "setl %al" & LF
           & HT & "movb %al, -29(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "signed less-than compares left minus right and stores its bool");
      end;
   end Signed_Less_Than_Compares_Left_With_Right;

   --  Equality ignores signedness, while the four ordered relations each
   --  have their own signed condition.  Pin the complete [1820] comparison
   --  level so no two source operators quietly become one machine verdict.
   procedure Every_Signed_Comparison_Selects_Its_Condition
     (Item : in out Landin.Testing.Context);

   procedure Every_Signed_Comparison_Selects_Its_Condition
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i16, b: i16) -> (r: bool) =" & LF
         & "    equal: bool = a == b" & LF
         & "    unequal: bool = a <> b" & LF
         & "    less: bool = a < b" & LF
         & "    at_most: bool = a <= b" & LF
         & "    greater: bool = a > b" & LF
         & "    r = a >= b" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "sete %al"),
            "equality uses the equal condition");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setne %al"),
            "inequality uses the not-equal condition");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setl %al"),
            "signed less-than uses the less condition");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setle %al"),
            "signed less-or-equal uses the at-most condition");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setg %al"),
            "signed greater-than uses the greater condition");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setge %al"),
            "signed greater-or-equal uses the at-least condition");
      end;
   end Every_Signed_Comparison_Selects_Its_Condition;

   --  Unsigned order is below/above rather than signed less/greater.  bool
   --  shares those conditions over [1870]'s zero and one, and still compares
   --  at its own one-byte width rather than the bool result choosing a width.
   procedure Unsigned_And_Bool_Comparisons_Use_Their_Conditions
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_And_Bool_Comparisons_Use_Their_Conditions
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u64, b: u64) -> (r: bool) =" & LF
         & "    below: bool = a < b" & LF
         & "    at_most: bool = a <= b" & LF
         & "    above: bool = a > b" & LF
         & "    r = a >= b" & LF
         & "end f" & LF
         & "g: (a: bool, b: bool) -> (r: bool) =" & LF
         & "    r = a < b" & LF
         & "end g" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "cmpq "),
            "u64 operands select a quadword comparison");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setb %al"),
            "unsigned less-than uses below");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setbe %al"),
            "unsigned less-or-equal uses below-or-equal");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "seta %al"),
            "unsigned greater-than uses above");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setae %al"),
            "unsigned greater-or-equal uses above-or-equal");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "cmpb "),
            "bool operands select a byte comparison");
      end;
   end Unsigned_And_Bool_Comparisons_Use_Their_Conditions;

   --  D125 leaves aggregate join storage in neutral IR.  The x86 backend
   --  lays that one cell out once, makes both arms fill it, and passes its
   --  address only after both edges have reached the join.
   procedure An_Aggregate_Control_Join_Passes_One_Caller_Cell
     (Item : in out Landin.Testing.Context);

   procedure An_Aggregate_Control_Join_Passes_One_Caller_Cell
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "pair: type = struct" & LF
         & "    left: i32" & LF
         & "    right: i32" & LF
         & "end pair" & LF
         & "take: (value: pair) -> (result: i32) =" & LF
         & "    result = value.left + value.right" & LF
         & "end take" & LF
         & "use: (flag: bool) -> (result: i32) =" & LF
         & "    result = take(if flag then" & LF
         & "        pair(left: 19, right: 23)" & LF
         & "    else" & LF
         & "        pair(left: 21, right: 21)" & LF
         & "    end if)" & LF
         & "end use" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      declare
         Whole : constant String := Emitted (Work);
         Use_At : constant Positive :=
           Positive (Index (Whole, "use:" & LF));
         Text : constant String := Whole (Use_At .. Whole'Last);
      begin
         Landin.Testing.Check
           (Item,
            Occurrences (Text, HT & "movl %eax, -16(%rbp)" & LF) = 2
              and then Occurrences
                (Text, HT & "movl %eax, -12(%rbp)" & LF) = 2,
            "both arms fill the same two-field caller cell");
         Landin.Testing.Check
           (Item,
            Occurrences (Text, HT & "jmp .L2_4" & LF) = 2
              and then Contains
                (Text,
                 ".L2_4:" & LF
                 & HT & "leaq -16(%rbp), %rax" & LF),
            "both control edges join before the caller forms its address");
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "call take" & LF)
              and then Contains (Whole, HT & "movabsq $8, %rcx" & LF)
              and then Occurrences (Whole, HT & "rep movsb" & LF) = 1,
            "the callee copies the joined cell at target-derived extent");
      end;
   end An_Aggregate_Control_Join_Passes_One_Caller_Cell;

   --  A runtime trap path stops at `ud2`; only the instruction path that
   --  survives the checked operation reaches normal block cleanup.  The
   --  backend receives ordinary calls from lowering and preserves their
   --  lexical reverse order without owning unwind policy.
   procedure Deferred_Calls_Follow_The_Normal_Path_After_Traps
     (Item : in out Landin.Testing.Context);

   procedure Deferred_Calls_Follow_The_Normal_Path_After_Traps
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "mut divisor: i32 = 0" & LF
         & "first: () -> none = end first" & LF
         & "second: () -> none = end second" & LF
         & "public main: () -> (code: i32) =" & LF
         & "    defer first()" & LF
         & "    defer second()" & LF
         & "    code = 42 / divisor" & LF
         & "end main" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "checked division with deferred cleanup is lowered");

      declare
         Whole : constant String := Emitted (Work);
         Main_At : constant Positive :=
           Positive (Index (Whole, "main:" & LF));
         Text : constant String := Whole (Main_At .. Whole'Last);
         Trap_At : constant Natural := Index (Text, HT & "ud2" & LF);
         Second_At : constant Natural :=
           Index (Text, HT & "call second" & LF);
         First_At : constant Natural :=
           Index (Text, HT & "call first" & LF);
      begin
         Landin.Testing.Check
           (Item,
            Trap_At > 0 and then Second_At > Trap_At
              and then First_At > Second_At,
            "the trap stops before normal reverse-order cleanup calls");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Text, HT & "call second" & LF), 1,
            "the later defer emits one call");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Text, HT & "call first" & LF), 1,
            "the earlier defer emits one call");
      end;
   end Deferred_Calls_Follow_The_Normal_Path_After_Traps;

   --  [1110] reaches x86 only as calls placed on the neutral failure block.
   --  They retain lexical reverse order before the dedicated error carrier
   --  is restored, while a successful return emits no undo call at all.
   procedure Undo_Calls_Precede_Only_The_Failure_Carrier
     (Item : in out Landin.Testing.Context);

   procedure Undo_Calls_Precede_Only_The_Failure_Carrier
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "bad: atom" & LF
         & "problem: type = bad" & LF
         & "first: () -> none = end first" & LF
         & "second: () -> none = end second" & LF
         & "failure_only: () -> none ! problem =" & LF
         & "    undo first()" & LF
         & "    undo second()" & LF
         & "    fail bad" & LF
         & "end failure_only" & LF
         & "success: () -> none ! problem =" & LF
         & "    undo first()" & LF
         & "    return" & LF
         & "end success" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "failure-only cleanup reaches backend-ready IR");

      declare
         Whole : constant String := Emitted (Work);
         Failure_At : constant Positive :=
           Positive (Index (Whole, "failure_only:" & LF));
         Success_At : constant Positive :=
           Positive (Index (Whole, "success:" & LF));
         Failure_Text : constant String :=
           Whole (Failure_At .. Success_At - 1);
         Success_Text : constant String := Whole (Success_At .. Whole'Last);
         Second_At : constant Natural :=
           Index (Failure_Text, HT & "call second" & LF);
         First_At : constant Natural :=
           Index (Failure_Text, HT & "call first" & LF);
         Error_At : constant Natural :=
           Index (Failure_Text, ", %r10d" & LF);
      begin
         Landin.Testing.Check
           (Item,
            Second_At > 0 and then First_At > Second_At
              and then Error_At > First_At,
            "reverse undo calls finish before failure propagation");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Failure_Text, HT & "call second" & LF), 1,
            "the later undo emits once on failure");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Failure_Text, HT & "call first" & LF), 1,
            "the earlier undo emits once on failure");
         Landin.Testing.Check
           (Item,
            not Contains (Success_Text, HT & "call first" & LF)
              and then not Contains
                (Success_Text, HT & "call second" & LF),
            "a successful return contains no undo call");
      end;
   end Undo_Calls_Precede_Only_The_Failure_Carrier;

   ------------------------------------------------------------------
   --  The frame
   ------------------------------------------------------------------

   --  A cell starts at a distance that is a multiple of its alignment,
   --  so the address it names is aligned and not merely reached by an
   --  aligned count.
   procedure Every_Cell_Is_Aligned_Below_The_Frame_Pointer
     (Item : in out Landin.Testing.Context);

   procedure Every_Cell_Is_Aligned_Below_The_Frame_Pointer
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      --  A byte, then something eight wide: the second has to be pushed
      --  past the first rather than laid beside it.
      Lower
        (Work,
         "f: (a: u8, b: u64) -> (r: u64) =" & LF
         & "    r = b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

      declare
         Unit   : IR.Unit renames Landin.Stages.Code (Work).all;
         One    : constant IR.Item_Id := 1;
         Layout : constant Landin.Backend.Frame :=
           Landin.Backend.Laid_Out
             (Unit, One, Landin.Stages.Target (Work));
         Sound  : Boolean := True;
      begin
         for Which in 1 .. IR.Slot_Count (Unit, One) loop
            declare
               Slot : constant IR.Slot_Id := IR.Slot_Id (Which);
               Wide : constant Landin.Targets.Scalar_Size :=
                 Landin.Backend.Size_Of
                   (IR.Type_Of (Unit, One, Slot),
                    Landin.Stages.Target (Work));
               Where : constant Landin.Targets.Byte_Count :=
                 Landin.Backend.Slot_Offset (Layout, Slot);
               Needs : constant Landin.Targets.Byte_Alignment :=
                 Landin.Targets.Alignment_Of
                   (Landin.Stages.Target (Work), Wide);
            begin
               if Where mod Landin.Targets.Byte_Count (Needs) /= 0
                 or else Where
                         < Landin.Targets.Byte_Count
                             (Landin.Targets.Bytes (Wide))
               then
                  Sound := False;
               end if;
            end;
         end loop;

         Landin.Testing.Check
           (Item, Sound, "every slot's cell is aligned and fits below it");
         Landin.Testing.Check
           (Item,
            Landin.Backend.Extent (Layout)
              mod Landin.Targets.Byte_Count
                    (Landin.Targets.Stack_Alignment
                       (Landin.Stages.Target (Work)))
              = 0,
            "the frame leaves the stack as aligned as it found it");
      end;
   end Every_Cell_Is_Aligned_Below_The_Frame_Pointer;

   --  Nothing outside Landin.Targets may ask the host how wide a pointer
   --  is, so the same item laid out against a 32-bit description gives a
   --  usize cell four bytes on this 64-bit host.
   procedure A_Frame_Follows_The_Target_And_Not_The_Host
     (Item : in out Landin.Testing.Context);

   procedure A_Frame_Follows_The_Target_And_Not_The_Host
     (Item : in out Landin.Testing.Context) is
   begin
      Landin.Testing.Check
        (Item,
         Landin.Backend.Size_Of
           (Landin.Types.Usize, Landin.Targets.Synthetic_32)
         = Landin.Targets.Byte_4,
         "usize is four bytes on a 32-bit description");
      Landin.Testing.Check
        (Item,
         Landin.Backend.Size_Of
           (Landin.Types.Usize, Landin.Targets.Linux_X86_64)
         = Landin.Targets.Byte_8,
         "and eight on a 64-bit one");
      --  [0150]: outside a packed struct a one-bit field occupies the
      --  next machine width, which is a byte.
      Landin.Testing.Check
        (Item,
         Landin.Backend.Size_Of
           (Landin.Types.Bool, Landin.Targets.Linux_X86_64)
         = Landin.Targets.Byte_1,
         "a bool occupies the next machine width above one bit");
   end A_Frame_Follows_The_Target_And_Not_The_Host;

   procedure Declared_Errors_Use_The_Dedicated_Register
     (Item : in out Landin.Testing.Context);

   procedure Declared_Errors_Use_The_Dedicated_Register
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "bad: atom" & LF
         & "problem: type = bad" & LF
         & "operation: type = (fails: bool) -> (value: i32) ! problem" & LF
         & "leaf: (fails: bool) -> (value: i32) ! problem =" & LF
         & "    fail bad when fails" & LF
         & "    value = 42" & LF
         & "end leaf" & LF
         & "public main: () -> (code: i32) =" & LF
         & "    indirect: operation = leaf" & LF
         & "    code = indirect(false) else 1" & LF
         & "end main" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");
      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, "movl %r10d, "),
            "a caller captures the dedicated error carrier");
         Landin.Testing.Check
           (Item, Contains (Text, "movl ") and then Contains (Text, ", %r10d"),
            "fail writes the dedicated error carrier");
         Landin.Testing.Check
           (Item, Contains (Text, "xorl %r10d, %r10d"),
            "a successful failing-signature return clears the carrier");
         Landin.Testing.Check
           (Item, Contains (Text, "call *"),
            "the same carrier surrounds an indirect call");
      end;
   end Declared_Errors_Use_The_Dedicated_Register;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "backend", "a constant return emits its whole frame",
         A_Constant_Return_Emits_Its_Whole_Frame'Access);
      Landin.Testing.Register
        (Into, "backend", "only a public routine is made global",
         Only_A_Public_Routine_Is_Made_Global'Access);
      Landin.Testing.Register
        (Into, "backend", "a parameter is stored from its register",
         A_Parameter_Is_Stored_From_Its_Register'Access);
      Landin.Testing.Register
        (Into, "backend", "a branch names both of its edges",
         A_Branch_Names_Both_Of_Its_Edges'Access);
      Landin.Testing.Register
        (Into, "backend", "an aggregate control join passes one caller cell",
         An_Aggregate_Control_Join_Passes_One_Caller_Cell'Access);
      Landin.Testing.Register
        (Into, "backend", "deferred calls follow normal paths after traps",
         Deferred_Calls_Follow_The_Normal_Path_After_Traps'Access);
      Landin.Testing.Register
        (Into, "backend", "undo calls precede only the failure carrier",
         Undo_Calls_Precede_Only_The_Failure_Carrier'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned add uses carry to trap",
         Unsigned_Add_Uses_Carry_To_Trap'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned subtract uses borrow to trap",
         Unsigned_Subtract_Uses_Borrow_To_Trap'Access);
      Landin.Testing.Register
        (Into, "backend", "signed add uses overflow to trap",
         Signed_Add_Uses_Overflow_To_Trap'Access);
      Landin.Testing.Register
        (Into, "backend", "signed subtract follows the target width",
         Signed_Subtract_Follows_The_Target_Width'Access);
      Landin.Testing.Register
        (Into, "backend", "a measurement follows the target",
         A_Measurement_Follows_The_Target'Access);
      Landin.Testing.Register
        (Into, "backend", "variant array payload writes follow the target",
         Variant_Array_Payload_Writes_Follow_The_Target'Access);
      Landin.Testing.Register
        (Into, "backend", "the same source emits the same bytes",
         The_Same_Source_Emits_The_Same_Bytes'Access);
      Landin.Testing.Register
        (Into, "backend", "an element is read at its own offset",
         An_Element_Is_Read_At_Its_Own_Offset'Access);
      Landin.Testing.Register
        (Into, "backend", "a computed element is checked before its address",
         A_Computed_Element_Is_Checked_Before_Its_Address'Access);
      Landin.Testing.Register
        (Into, "backend",
         "a computed local element reaches its slot",
         A_Computed_Local_Element_Reaches_Its_Slot'Access);
      Landin.Testing.Register
        (Into, "backend", "an array state is reserved whole",
         An_Array_State_Is_Reserved_Whole'Access);
      Landin.Testing.Register
        (Into, "backend", "a module array literal becomes data image",
         A_Module_Array_Literal_Becomes_Data_Image'Access);
      Landin.Testing.Register
        (Into, "backend",
         "module repetition uses compact full-width directives",
         Module_Repetition_Uses_Compact_Full_Width_Directives'Access);
      Landin.Testing.Register
        (Into, "backend", "zero data is reserved and not written",
         Zero_Data_Is_Reserved_And_Not_Written'Access);
      Landin.Testing.Register
        (Into, "backend", "a zeroed module scalar stays in bss",
         A_Zeroed_Module_Scalar_Stays_In_Bss'Access);
      Landin.Testing.Register
        (Into, "backend", "a module value becomes initialized data",
         A_Module_Value_Becomes_Initialized_Data'Access);
      Landin.Testing.Register
        (Into, "backend", "a module binding is reached through rip",
         A_Module_Binding_Is_Reached_Through_Rip'Access);
      Landin.Testing.Register
        (Into, "backend", "a struct state becomes zeroed data",
         A_Struct_State_Becomes_Zeroed_Data'Access);
      Landin.Testing.Register
        (Into, "backend", "a struct state follows its target",
         A_Struct_State_Follows_Its_Target'Access);
      Landin.Testing.Register
        (Into, "backend", "a module struct literal becomes data image",
         A_Module_Struct_Literal_Becomes_Data_Image'Access);
      Landin.Testing.Register
        (Into, "backend", "a recursive module image follows its target",
         A_Recursive_Module_Image_Follows_Its_Target'Access);
      Landin.Testing.Register
        (Into, "backend", "a field is read at its own offset",
         A_Field_Is_Read_At_Its_Own_Offset'Access);
      Landin.Testing.Register
        (Into, "backend", "a field after a wide array uses registers",
         A_Field_After_A_Wide_Array_Uses_A_Register_Address'Access);
      Landin.Testing.Register
        (Into, "backend", "an array field after a wide field uses registers",
         An_Array_Field_After_A_Wide_Field_Uses_Registers'Access);
      Landin.Testing.Register
        (Into, "backend", "array field literal stores follow their target",
         Array_Field_Literal_Stores_Follow_Their_Target'Access);
      Landin.Testing.Register
        (Into, "backend", "array field repetition fills follow their target",
         Array_Field_Repetition_Fills_Follow_Their_Target'Access);
      Landin.Testing.Register
        (Into, "backend", "array-bearing struct copy derives field addresses",
         Array_Bearing_Struct_Copy_Derives_Field_Addresses'Access);
      Landin.Testing.Register
        (Into, "backend", "local struct initializer derives field addresses",
         Local_Struct_Initializer_Derives_Field_Addresses'Access);
      Landin.Testing.Register
        (Into, "backend", "inferred local struct derives field addresses",
         Inferred_Local_Struct_Derives_Field_Addresses'Access);
      Landin.Testing.Register
        (Into, "backend", "a wide array field clear uses registers",
         A_Wide_Array_Field_Clear_Uses_Registers'Access);
      Landin.Testing.Register
        (Into, "backend", "array field copy derives both addresses",
         Array_Field_Copy_Derives_Both_Target_Addresses'Access);
      Landin.Testing.Register
        (Into, "backend", "array field initializer derives source address",
         Array_Field_Initializer_Derives_Its_Source_Address'Access);
      Landin.Testing.Register
        (Into, "backend", "a field is written at its own offset",
         A_Field_Is_Written_At_Its_Own_Offset'Access);
      Landin.Testing.Register
        (Into, "backend", "a struct local is a cell in the frame",
         A_Struct_Local_Is_A_Cell_In_The_Frame'Access);
      Landin.Testing.Register
        (Into, "backend", "a struct array field local follows its target",
         A_Struct_Array_Field_Local_Follows_Its_Target'Access);
      Landin.Testing.Register
        (Into, "backend", "an empty array slot field has identity extent",
         An_Empty_Array_Slot_Field_Has_Identity_Extent'Access);
      Landin.Testing.Register
        (Into, "backend", "constant array parts share one frame cell",
         Constant_Array_Parts_Address_One_Frame_Cell'Access);
      Landin.Testing.Register
        (Into, "backend", "an array copy moves a constant target extent",
         An_Array_Copy_Moves_A_Constant_Target_Extent'Access);
      Landin.Testing.Register
        (Into, "backend", "a local array clear follows the target extent",
         A_Local_Array_Clear_Follows_The_Target_Extent'Access);
      Landin.Testing.Register
        (Into, "backend", "a module array clear follows the target extent",
         A_Module_Array_Clear_Follows_The_Target_Extent'Access);
      Landin.Testing.Register
        (Into, "backend", "a module struct clear follows target extent",
         A_Module_Struct_Clear_Follows_The_Target_Extent'Access);
      Landin.Testing.Register
        (Into, "backend", "a nested struct clear follows target extent",
         A_Nested_Struct_Clear_Follows_The_Target_Extent'Access);
      Landin.Testing.Register
        (Into, "backend", "an ordinary child clear follows the target",
         An_Ordinary_Child_Clear_Follows_The_Target'Access);
      Landin.Testing.Register
        (Into, "backend", "a nested scalar field follows the target",
         A_Nested_Scalar_Field_Follows_The_Target'Access);
      Landin.Testing.Register
        (Into, "backend", "a nested array element follows the target",
         A_Nested_Array_Element_Follows_The_Target'Access);
      Landin.Testing.Register
        (Into, "backend", "nested array values follow the target",
         Nested_Array_Values_Follow_The_Target'Access);
      Landin.Testing.Register
        (Into, "backend", "an array fill follows the target element width",
         An_Array_Fill_Follows_The_Target_Element_Width'Access);
      Landin.Testing.Register
        (Into, "backend", "a module value folds every level",
         A_Module_Value_Folds_Every_Level'Access);
      Landin.Testing.Register
        (Into, "backend", "a call fills its argument registers in order",
         A_Call_Fills_Its_Argument_Registers_In_Order'Access);
      Landin.Testing.Register
        (Into, "backend", "a call returning none keeps nothing",
         A_Call_Returning_None_Keeps_Nothing'Access);
      Landin.Testing.Register
        (Into, "backend", "declared errors use the dedicated register",
         Declared_Errors_Use_The_Dedicated_Register'Access);
      Landin.Testing.Register
        (Into, "backend", "six arguments reach their own widths",
         Six_Arguments_Reach_Their_Own_Widths'Access);
      Landin.Testing.Register
        (Into, "backend", "stack arguments cross the call",
         Stack_Arguments_Cross_The_Call'Access);
      Landin.Testing.Register
        (Into, "backend", "aggregate arguments are copied in the callee",
         Aggregate_Arguments_Are_Copied_In_The_Callee'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned shift left zeroes beyond the width",
         Unsigned_Shift_Left_Zeroes_Beyond_The_Width'Access);
      Landin.Testing.Register
        (Into, "backend", "signed shift right traps a negative amount",
         Signed_Shift_Right_Traps_A_Negative_Amount'Access);
      Landin.Testing.Register
        (Into, "backend", "a signed shift beyond the width is zero",
         A_Signed_Shift_Beyond_The_Width_Is_Zero'Access);
      Landin.Testing.Register
        (Into, "backend", "complement inverts without a trap",
         Complement_Inverts_Without_A_Trap'Access);
      Landin.Testing.Register
        (Into, "backend", "signed negation traps on the lowest value",
         Signed_Negation_Traps_On_The_Lowest_Value'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned negation uses carry to trap",
         Unsigned_Negation_Uses_Carry_To_Trap'Access);
      Landin.Testing.Register
        (Into, "backend", "logical not flips the one byte bool",
         Logical_Not_Flips_The_One_Byte_Bool'Access);
      Landin.Testing.Register
        (Into, "backend", "every bitwise operator selects its instruction",
         Every_Bitwise_Operator_Selects_Its_Instruction'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned divide guards zero and stores quotient",
         Unsigned_Divide_Guards_Zero_And_Stores_The_Quotient'Access);
      Landin.Testing.Register
        (Into, "backend", "signed divide guards overflow and truncates",
         Signed_Divide_Guards_Overflow_And_Truncates'Access);
      Landin.Testing.Register
        (Into, "backend", "signed remainder handles minimum modulo minus one",
         Signed_Remainder_Handles_Minimum_Modulo_Minus_One'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned multiply uses the full product",
         Unsigned_Multiply_Uses_The_Full_Product'Access);
      Landin.Testing.Register
        (Into, "backend", "signed multiply uses overflow to trap",
         Signed_Multiply_Uses_Overflow_To_Trap'Access);
      Landin.Testing.Register
        (Into, "backend", "wrapping multiply keeps the low product",
         Wrapping_Multiply_Keeps_The_Low_Product'Access);
      Landin.Testing.Register
        (Into, "backend", "wrapping add ignores overflow",
         Wrapping_Add_Ignores_Overflow'Access);
      Landin.Testing.Register
        (Into, "backend", "wrapping subtract follows the target width",
         Wrapping_Subtract_Follows_The_Target_Width'Access);
      Landin.Testing.Register
        (Into, "backend", "signed less-than compares left with right",
         Signed_Less_Than_Compares_Left_With_Right'Access);
      Landin.Testing.Register
        (Into, "backend", "every signed comparison selects its condition",
         Every_Signed_Comparison_Selects_Its_Condition'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned and bool comparisons use their conditions",
         Unsigned_And_Bool_Comparisons_Use_Their_Conditions'Access);
      Landin.Testing.Register
        (Into, "backend", "every cell is aligned below the frame pointer",
         Every_Cell_Is_Aligned_Below_The_Frame_Pointer'Access);
      Landin.Testing.Register
        (Into, "backend", "a frame follows the target and not the host",
         A_Frame_Follows_The_Target_And_Not_The_Host'Access);
   end Register;

end Landin.Tests.Backend_Suite;
