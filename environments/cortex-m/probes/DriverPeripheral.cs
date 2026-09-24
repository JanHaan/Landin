// Derived driver's separately justified synthetic protocol, NOT an RP2040 emulator.
// Literal register oracle; consumes neither generated sources nor metadata.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
namespace Antmicro.Renode.Peripherals.Miscellaneous
{
 public class DriverPeripheral : IDoubleWordPeripheral, IWordPeripheral, IBytePeripheral, IKnownSize
 {
  public DriverPeripheral(IMachine machine) { this.machine=machine; Reset(); }
  public long Size { get { return 0x2000; } }
  public GPIO IRQ { get; } = new GPIO();
  public GPIO TimerIRQ { get; } = new GPIO();
  public string Trace { get { return String.Join(";",events); } }
  public string OutputBytes { get { return String.Join(",",outputBytes); } }
  public uint Remaining { get; private set; }
  public uint Transfers { get; private set; }
  public uint Configuration { get; private set; }
  public uint Output { get; private set; }
  public uint Pending { get; private set; }
  public uint Alarm { get; private set; }
  public bool AlarmPending { get { return timerPending != 0; } }
  public uint IntegerDivisor { get; private set; }
  public uint FractionDivisor { get; private set; }
  public uint LineControl { get; private set; }
  public uint DMAControl { get; private set; }
  public uint Rejected { get; private set; }
  public uint GPIO0 { get; private set; }
  public uint GPIO1 { get; private set; }
  public bool Busy { get { return busy; } }
  public void Reset()
  {
   events.Clear(); outputBytes.Clear(); GPIO0=GPIO1=0x3000001f;
   Remaining=Transfers=Configuration=Output=Pending=Alarm=0;
   IntegerDivisor=FractionDivisor=LineControl=DMAControl=Rejected=0;
   source=destination=enabled=timerPending=clock=errors=0;
   busy=false; alarmArmed=false; stopReads=0; stopDelay=0; pendingByte=-1;
   IRQ.Unset(); TimerIRQ.Unset();
  }
  public void ClearTrace() { events.Clear(); }
  public void DelayStop(int reads, int value)
  { if(reads<0 || value>255 || value< -1) throw new InvalidOperationException("bad stop injection"); stopDelay=reads; pendingByte=value; }
  public void InjectError() { errors=0x20000000; Configuration &= ~1u; busy=false; Pending|=1; Notify(); }
  // Explicit external maintenance after proven quiescence, not a driver write.
  public void Repair() { if(busy) throw new InvalidOperationException("repair while active"); errors=0; }
  public void Tick(uint amount)
  {
   uint distance=unchecked(Alarm-clock);
   clock=unchecked(clock+amount);
   if(alarmArmed && distance<=amount)
   { alarmArmed=false; timerPending|=1; TimerIRQ.Set(true); }
  }
  public uint ReadDoubleWord(long offset)
  {
   uint value;
   switch(offset)
   {
    case 4: value=GPIO0; break;
    case 12: value=GPIO1; break;
    case 0x110: value=Output; break;
    case 0x218: value=0x90; break;
    case 0x328: value=clock; break;
    case 0x334: value=timerPending; break;
    case 0x1008: value=Remaining; break;
    case 0x100c:
     if((Configuration&1)==0 && busy)
     {
      if(pendingByte>=0) { Transfer((uint)pendingByte); pendingByte=-1; }
      if(stopReads>0) stopReads--; else busy=false;
     }
     value=Configuration|errors|(busy?0x01000000u:0); break;
    case 0x1400: value=Pending; break;
    default: throw new InvalidOperationException("forbidden driver read");
   }
   events.Add(String.Format("r32:{0:x}:{1:x8}",offset,value)); return value;
  }
  public void WriteDoubleWord(long offset,uint value)
  {
   switch(offset)
   {
    case 4: Check(value,0x3003331f); GPIO0=value; break;
    case 12: Check(value,0x3003331f); GPIO1=value; break;
    case 0x114: Check(value,0x3fffffff); Output|=value; break;
    case 0x118: Check(value,0x3fffffff); Output&=~value; break;
    case 0x200: Check(value,255); outputBytes.Add(value); break;
    case 0x224: Check(value,65535); IntegerDivisor=value; break;
    case 0x228: Check(value,63); FractionDivisor=value; break;
    case 0x22c: Check(value,255); LineControl=value; break;
    case 0x248: Check(value,7); DMAControl=value; break;
    case 0x244: Check(value,0x7ff); break;
    case 0x310: Alarm=value; alarmArmed=true; break;
    case 0x334: Check(value,15); timerPending&=~value; TimerIRQ.Set(timerPending!=0); break;
    case 0x1000: Idle(); source=value; break;
    case 0x1004: Idle(); destination=value; break;
    case 0x1008:
     Idle(); if(value==0 || value>65535) throw new InvalidOperationException("finite DMA count");
     Remaining=value; Transfers=0; break;
    case 0x100c:
     Check(value,0xffffff);
     if((value&~0x3c1u)!=0xa8420) throw new InvalidOperationException("wrong byte/ring/request config");
     if((value&1)==0 && (Configuration&1)!=0) stopReads=stopDelay;
     Configuration=value;
     if((value&1)!=0)
     {
      uint size=1u<<(int)((value>>6)&15);
      if(size<2 || size>256 || destination%size!=0 || source!=0x40070200 ||
         destination<0x20000000 || (ulong)destination+size>0x20003000 || errors!=0)
       throw new InvalidOperationException("invalid ring descriptor");
      busy=Remaining!=0;
     }
     else if(stopReads==0 && pendingByte<0) busy=false;
     break;
    case 0x1400: Check(value,1); Pending&=~value; break;
    case 0x1404: Check(value,1); enabled=value; break;
    default: throw new InvalidOperationException("forbidden driver write");
   }
   events.Add(String.Format("w32:{0:x}:{1:x8}",offset,value)); Notify();
  }
  public void Feed(uint value)
  {
   if(value>255) throw new InvalidOperationException("not a byte");
   if((Configuration&1)==0 || Remaining==0 || errors!=0) { Rejected++; return; }
   Transfer(value);
  }
  private void Transfer(uint value)
  {
   if(Remaining==0) throw new InvalidOperationException("counter exhausted");
   uint size=1u<<(int)((Configuration>>6)&15);
   uint index=Transfers%size;
   machine.SystemBus.WriteByte(destination+index,(byte)value);
   events.Add(String.Format("dma8:{0}:{1:x2}",index,value));
   Transfers++; Remaining--;
   // Data publication precedes the monotone count. Half/full are coalescing
   // hints only. Ring addresses wrap; this transfer count NEVER reloads.
   if(Transfers%(size/2)==0 || Remaining==0) Pending|=1;
   if(Remaining==0) { Configuration&=~1u; busy=false; }
   Notify();
  }
  private void Idle() { if(busy) throw new InvalidOperationException("descriptor changed before drain"); }
  private void Notify() { IRQ.Set((Pending&enabled)!=0); }
  private static void Check(uint value,uint mask) { if((value&~mask)!=0) throw new InvalidOperationException("reserved bits"); }
  public ushort ReadWord(long offset) { throw new InvalidOperationException("word MMIO required"); }
  public void WriteWord(long offset,ushort value) { throw new InvalidOperationException("word MMIO required"); }
  public byte ReadByte(long offset) { throw new InvalidOperationException("word MMIO required"); }
  public void WriteByte(long offset,byte value) { throw new InvalidOperationException("word MMIO required"); }
  private readonly IMachine machine;
  private readonly List<string> events=new List<string>();
  private readonly List<uint> outputBytes=new List<uint>();
  private uint source,destination,enabled,timerPending,clock,errors;
  private bool busy,alarmArmed;
  private int stopReads,stopDelay,pendingByte;
 }
}
