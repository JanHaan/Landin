// Independent literal R6.80 contract. Not a faithful RP2040 emulation.
// No SVD, generated Landin, or projection tables are consumed here.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public class FixturePeripheral : IDoubleWordPeripheral, IWordPeripheral, IBytePeripheral, IKnownSize
    {
        public FixturePeripheral(IMachine machine) { this.machine = machine; Reset(); }
        public long Size { get { return 0x2000; } }
        public GPIO IRQ { get; } = new GPIO();
        public string Trace { get { return String.Join(";", events); } }
        public uint Remaining { get; private set; }
        public uint Transfers { get; private set; }
        public uint Configuration { get; private set; }
        public uint Output { get; private set; }
        public uint Transmitted { get; private set; }
        public uint Pending { get; private set; }
        public uint Alarm { get; private set; }
        public void Reset()
        {
            events.Clear(); gpio = 31; fifo = 0; Output = Transmitted = 0;
            Remaining = Transfers = Configuration = Pending = 0;
            source = destination = enabled = 0; timerPending = 3; Alarm = 0;
            IRQ.Unset();
        }
        public void SetGPIO(uint value) { gpio = value; }
        public uint ReadDoubleWord(long offset)
        {
            uint value;
            switch(offset)
            {
                case 4: value = gpio; break;
                case 0x104: value = 0; break;
                case 0x110: value = Output; break;
                case 0x200:
                    if(fifo > 1) throw new InvalidOperationException("empty synthetic FIFO");
                    value = 0x41 + fifo++; break;
                case 0x218: value = 0x90; break;
                case 0x328: value = 7; break;
                case 0x334: value = timerPending; break;
                case 0x1008: value = Remaining; break;
                case 0x100c: value = Configuration | (Remaining != 0 ? 0x1000000u : 0); break;
                case 0x1400: value = Pending; break;
                default: throw new InvalidOperationException("forbidden read or unknown fixture register");
            }
            events.Add(String.Format("r32:{0:x}:{1:x8}", offset, value));
            return value;
        }
        public void WriteDoubleWord(long offset, uint value)
        {
            switch(offset)
            {
                case 4: Check(value, 0x3003331f); gpio = value; break;
                case 0x114: Check(value, 0x3fffffff); Output |= value; break;
                case 0x118: Check(value, 0x3fffffff); Output &= ~value; break;
                case 0x200: Check(value, 0xff); Transmitted = value; break;
                case 0x244: Check(value, 0x7ff); break;
                case 0x310: Alarm = value; break;
                case 0x334: Check(value, 0xf); timerPending &= ~value; break;
                case 0x1000: source = value; break;
                case 0x1004: destination = value; break;
                case 0x1008:
                    if(value != 4) throw new InvalidOperationException("only four-byte fixture DMA");
                    Remaining = value; break;
                case 0x100c:
                    if(value != 0xa8020 && value != 0xa8021)
                        throw new InvalidOperationException("unsupported synthetic DMA config");
                    Configuration = value; break;
                case 0x1400: Check(value, 0xffff); Pending &= ~value; break;
                case 0x1404: Check(value, 1); enabled = value; break;
                default: throw new InvalidOperationException("forbidden write or unknown fixture register");
            }
            events.Add(String.Format("w32:{0:x}:{1:x8}", offset, value));
            IRQ.Set((Pending & enabled) != 0);
        }
        // Explicit stopped-time premise: byte first, count/status afterward.
        // The half notification is synthetic and is not an RP2040 DMA feature.
        public void Feed(uint value)
        {
            if(value > 255 || (Configuration & 1) == 0 || Remaining == 0 ||
               source != 0x40070200 || destination < 0x20000000 ||
               (ulong)destination + 4 > 0x20003000)
                throw new InvalidOperationException("invalid synthetic DMA descriptor");
            machine.SystemBus.WriteByte(destination + Transfers, (byte)value);
            Transfers++; Remaining--;
            events.Add(String.Format("dma8:{0}:{1:x2}", Transfers-1, value));
            if(Remaining == 2 || Remaining == 0) Pending = 1;
            if(Remaining == 0) Configuration &= ~1u;
            IRQ.Set((Pending & enabled) != 0);
        }
        public ushort ReadWord(long offset) { throw new InvalidOperationException("word transaction required"); }
        public void WriteWord(long offset, ushort value) { throw new InvalidOperationException("word transaction required"); }
        public byte ReadByte(long offset) { throw new InvalidOperationException("word transaction required"); }
        public void WriteByte(long offset, byte value) { throw new InvalidOperationException("word transaction required"); }
        private static void Check(uint value, uint mask)
        {
            if((value & ~mask) != 0) throw new InvalidOperationException("reserved bits");
        }
        private readonly IMachine machine;
        private readonly List<string> events = new List<string>();
        private uint gpio, fifo, source, destination, enabled, timerPending;
    }
}
