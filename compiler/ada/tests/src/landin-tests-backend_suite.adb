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
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.Backend_Suite is

   package IR renames Landin.IR;

   function Contains (Text : String; Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   use type Landin.Source.Source_Id;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Scalar_Size;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "cmpb $0, "),
            "a bool is tested as the one byte it occupies");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jne .L1_3"),
            "the taken edge is the branch's target");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jmp .L1_4"),
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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

            Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & ".data" & LF
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

   --  The same declaration against a 32-bit description, so the size
   --  follows the target rather than the host: `usize bool` is sixteen
   --  bytes on Linux x86-64 and eight here.
   procedure A_Struct_State_Follows_Its_Target
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_State_Follows_Its_Target
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "machine: type = struct" & LF
        & "    word: usize" & LF
        & "    ready: bool" & LF
        & "end machine" & LF
        & "mut state: machine" & LF;
   begin
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Synthetic_32);
         Ran  : Natural;
      begin
         Lower (Work, Source, Ran);
         Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
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
                               & HT & ".zero 16" & LF),
               "a pointer-width field widens the state it is in");
         end;
      end;
   end A_Struct_State_Follows_Its_Target;

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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
           (Item, Contains (Text, HT & ".long 0" & LF),
            "D10's binding with no value holds zero");
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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, "sum:" & LF & HT & ".long 42" & LF),
            "an arithmetic fold reaches its value");
         Landin.Testing.Check
           (Item, Contains (Text, "derived:" & LF & HT & ".long 43" & LF),
            "a module value may name one folded above it");
         Landin.Testing.Check
           (Item, Contains (Text, "beyond:" & LF & HT & ".long 0" & LF),
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
      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Lower (Second, Source, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 4, "and four again");

      Landin.Testing.Check_Equal
        (Item, Emitted (First), Emitted (Second),
         "one source emits one text");
   end The_Same_Source_Emits_The_Same_Bytes;

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
        "here: usize = sizeof usize" & LF
        & "wide: usize = sizeof u32" & LF;

      Native : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Narrow : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Synthetic_32);
      Ran    : Natural;
   begin
      Lower (Native, Source, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Lower (Narrow, Source, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 4, "and four again");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

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
        (Into, "backend", "the same source emits the same bytes",
         The_Same_Source_Emits_The_Same_Bytes'Access);
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
        (Into, "backend", "a field is read at its own offset",
         A_Field_Is_Read_At_Its_Own_Offset'Access);
      Landin.Testing.Register
        (Into, "backend", "a field is written at its own offset",
         A_Field_Is_Written_At_Its_Own_Offset'Access);
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
        (Into, "backend", "six arguments reach their own widths",
         Six_Arguments_Reach_Their_Own_Widths'Access);
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
