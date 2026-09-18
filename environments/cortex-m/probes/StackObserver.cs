// Host-side register observation. No target instrumentation or MMIO reads.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;
namespace Antmicro.Renode.Peripherals.Miscellaneous
{
 public class StackObserver : IPeripheral
 {
  public StackObserver(IMachine machine, CortexM cpu)
  {
   this.machine=machine; this.cpu=cpu; Reset();
   // A one-instruction translation block gives a stable observation boundary
   // without breakpoint hooks repeatedly invalidating copied RAM code.
   cpu.MaximumBlockSize=1;
   cpu.SetHookAtBlockBegin((pc,size) => {
    if(size!=1) throw new InvalidOperationException("unexpected observation block size");
    if(sites.Contains(pc)) Sample(cpu,pc);
   });
  }
  public void Reset() { minimum=0x20004000; samples=0; record="null"; interrupts.Clear(); }
  public void Add(ulong address) { sites.Add(address); }
  public void Handler(ulong address) { handlers.Add(address); }
  public string Record
  {
   get
   {
    var entries=new List<string>();
    foreach(var item in interrupts) entries.Add("\""+item.Key+"\":"+item.Value);
    return "{\"samples\":"+samples+",\"minimum_sp\":"+minimum+
      ",\"minimum\":"+record+",\"interrupt_ipsr\":{"+String.Join(",",entries)+"}}";
   }
  }
  private void Sample(ICPU ignored, ulong pc)
  {
   uint sp=(uint)cpu.GetRegister(13).RawValue;
   if(sp<0x20003000 || sp>0x20004000) throw new InvalidOperationException("stack escaped reservation");
   samples++;
   if(handlers.Contains(pc))
   {
    uint ipsr=(uint)cpu.GetRegister(25).RawValue & 511;
    if(!interrupts.ContainsKey(ipsr) || sp<interrupts[ipsr]) interrupts[ipsr]=sp;
   }
   if(sp>=minimum) return;
   minimum=sp;
   uint fp=(uint)cpu.GetRegister(11).RawValue;
   uint lr=(uint)cpu.GetRegister(14).RawValue;
   uint psr=(uint)cpu.GetRegister(25).RawValue;
   var frames=new List<string>();
   uint cursor=fp;
   while(cursor>=sp && cursor<0x20003ff8 && cursor%4==0)
   {
    uint previous=machine.SystemBus.ReadDoubleWord(cursor);
    uint incoming=machine.SystemBus.ReadDoubleWord(cursor+4);
    frames.Add("["+cursor+","+previous+","+incoming+"]");
    if(incoming>=0xfffffff0 || previous<=cursor) break;
    cursor=previous;
   }
   record="{\"pc\":"+pc+",\"sp\":"+sp+",\"fp\":"+fp+",\"lr\":"+lr+
          ",\"xpsr\":"+psr+",\"frame_records\":["+String.Join(",",frames)+"]}";
  }
  private readonly IMachine machine;
  private readonly CortexM cpu;
  private readonly HashSet<ulong> handlers=new HashSet<ulong>();
  private readonly HashSet<ulong> sites=new HashSet<ulong>();
  private readonly Dictionary<uint,uint> interrupts=new Dictionary<uint,uint>();
  private uint minimum;
  private ulong samples;
  private string record;
 }
}
