// A deliberately synthetic prototype-1 contract model, not an STM32 model.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public class PrototypePeripheral : IDoubleWordPeripheral, IWordPeripheral, IKnownSize
    {
        public PrototypePeripheral(IMachine machine) { this.machine = machine; Reset(); }
        public long Size { get { return 0x7000; } }
        public GPIO IRQ { get; } = new GPIO();
        public uint Remaining { get { return count; } }
        public uint Configuration { get { return Get(0x6058); } }
        public uint CountHalfReads { get; private set; }
        public uint CountHalfWrites { get; private set; }
        public uint CountWordReads { get; private set; }
        public uint CountWordWrites { get; private set; }
        public uint Transfers { get; private set; }
        public uint Errors { get; private set; }
        public uint Reads { get; private set; }
        public uint Writes { get; private set; }
        public void Reset()
        {
            regs.Clear(); count = initial = position = status = 0;
            CountHalfReads = CountHalfWrites = CountWordReads = CountWordWrites = 0;
            Transfers = Errors = Reads = Writes = 0; IRQ.Unset();
        }
        public ushort ReadWord(long offset)
        {
            if(offset != 0x10 && offset != 0x14 && offset != 0x605c)
                throw new InvalidOperationException("unsupported halfword read");
            if(offset == 0x605c) { CountHalfReads++; Reads++; return (ushort)count; }
            return (ushort)ReadDoubleWord(offset);
        }
        public void WriteWord(long offset, ushort value)
        {
            if(offset != 0x14 && offset != 0x605c)
                throw new InvalidOperationException("unsupported halfword write");
            WriteDoubleWord(offset, value);
            if(offset == 0x605c) { CountHalfWrites++; CountWordWrites--; }
        }
        public void SetInput(ushort value) { regs[0x10] = value; }
        public uint ReadDoubleWord(long offset)
        {
            Reads++;
            if(offset == 0x6000) return status;
            if(offset == 0x605c) { CountWordReads++; return count; }
            if(offset == 0x6004 || offset == 0x18)
                throw new InvalidOperationException("read from write-only register");
            if(!Known(offset)) throw new InvalidOperationException("unsupported register read");
            return Get(offset);
        }
        public void WriteDoubleWord(long offset, uint value)
        {
            Writes++;
            if(offset == 0x6000 || offset == 0x10)
                throw new InvalidOperationException("write to read-only register");
            if(offset == 0x6004) { status &= ~value; UpdateIRQ(); return; }
            if(offset == 0x18) { regs[0x14] = (Get(0x14) | (value & 0xffff)) & ~(value >> 16); return; }
            if(!Known(offset)) throw new InvalidOperationException("unsupported register write");
            if(offset == 0x605c)
            {
                CountWordWrites++;
                if(value > 65535) throw new InvalidOperationException("count exceeds 16 bits");
                count = initial = value; position = 0;
            }
            regs[offset] = value;
            UpdateIRQ();
        }
        // Called only by a stopped-time test step; one UART byte per call.
        public void Feed(uint value)
        {
            if(value > 255) throw new InvalidOperationException("not a byte");
            regs[0x1004] = value;
            var cfg = Get(0x6058);
            if((cfg & 1) == 0) return;
            if(count == 0 || (cfg & 0xc0) != 0 || Get(0x6060) != 0x40021004
                || Get(0x6064) < 0x20000000 || (ulong)Get(0x6064) + initial > 0x20003000)
            { Error(); return; }
            machine.SystemBus.WriteByte(Get(0x6064) + ((cfg & 0x400) != 0 ? position : 0), (byte)value);
            Transfers++; position++; count--;
            if(count == initial / 2) status |= 0x40;
            if(count == 0)
            {
                status |= 0x20;
                if((cfg & 0x100) != 0) { count = initial; position = 0; }
                else regs[0x6058] = cfg & ~1u;
            }
            UpdateIRQ();
        }
        public void Error() { Errors++; status |= 0x80; regs[0x6058] = Get(0x6058) & ~1u; UpdateIRQ(); }
        private void UpdateIRQ()
        {
            var cfg = Get(0x6058);
            IRQ.Set(((status & 0x20) != 0 && (cfg & 2) != 0)
                || ((status & 0x40) != 0 && (cfg & 4) != 0)
                || ((status & 0x80) != 0 && (cfg & 8) != 0));
        }
        private uint Get(long offset) { return regs.TryGetValue(offset, out var value) ? value : 0; }
        private bool Known(long o)
        {
            return o == 0 || o == 4 || o == 8 || o == 12 || o == 0x10 || o == 0x14
                || o == 0x18 || o == 0x1c || o == 0x20 || o == 0x24
                || o == 0x1000 || o == 0x1004 || o == 0x6058 || o == 0x605c
                || o == 0x6060 || o == 0x6064;
        }
        private readonly IMachine machine;
        private readonly Dictionary<long, uint> regs = new Dictionary<long, uint>();
        private uint count, initial, position, status;
    }
}
