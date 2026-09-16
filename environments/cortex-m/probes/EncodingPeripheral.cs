// R6.40 bounded access contract, independent of the firmware bit algorithms.
// Synthetic device only: no vendor identification or physical bus claim.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public class EncodingPeripheral : IDoubleWordPeripheral, IWordPeripheral, IKnownSize
    {
        public EncodingPeripheral(IMachine machine) { Reset(); }
        public long Size { get { return 0x20; } }
        public string Trace { get { return String.Join(";", events); } }
        public uint Normal { get; private set; }
        public uint Command { get; private set; }
        public uint Pending { get; private set; }
        public ushort Count { get; private set; }
        public uint Ones { get; private set; }
        public void Reset()
        {
            events.Clear(); Normal = 0xa50000f0; destructive = 0x9b;
            Command = 0; Pending = 0xf3; Count = 0xffff;
            Ones = 0xffffff00;
        }
        public uint ReadDoubleWord(long offset)
        {
            uint value;
            switch(offset)
            {
                case 0: value = Normal; break;
                case 4: value = destructive; destructive = 0; break;
                case 8: throw new InvalidOperationException("write-only image");
                case 12: value = Pending; break;
                case 20: value = Ones; break;
                default: throw new InvalidOperationException("wrong read width or address");
            }
            events.Add(String.Format("r32:{0:x}:{1:x8}", offset, value));
            return value;
        }
        public void WriteDoubleWord(long offset, uint value)
        {
            switch(offset)
            {
                case 0:
                    // The device, not the bit algorithm, independently pins
                    // reserved bits 8..31 to their boot image.
                    if((value & 0xffffff00) != 0xa5000000)
                        throw new InvalidOperationException("reserved image changed");
                    Normal = value; break;
                case 8:
                    if((value & 0xffffff00) != 0)
                        throw new InvalidOperationException("command reserved bits must be zero");
                    Command = value; break;
                case 12:
                    if((value & 0xffffff00) != 0)
                        throw new InvalidOperationException("clear reserved bits must be zero");
                    Pending &= ~value; break;
                case 20:
                    if((value & 0xffffff00) != 0xffffff00)
                        throw new InvalidOperationException("reserved bits must be one");
                    Ones = value; break;
                default: throw new InvalidOperationException("forbidden write or width");
            }
            events.Add(String.Format("w32:{0:x}:{1:x8}", offset, value));
        }
        public ushort ReadWord(long offset)
        {
            if(offset != 16) throw new InvalidOperationException("wrong halfword read");
            events.Add(String.Format("r16:10:{0:x4}", Count));
            return Count;
        }
        public void WriteWord(long offset, ushort value)
        {
            if(offset != 16) throw new InvalidOperationException("wrong halfword write");
            Count = value;
            events.Add(String.Format("w16:10:{0:x4}", value));
        }
        private uint destructive;
        private readonly List<string> events = new List<string>();
    }
}
