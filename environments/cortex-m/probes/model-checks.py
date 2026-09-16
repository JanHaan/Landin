# Executable model limits and failure controls, inside Renode IronPython.
m = monitor.Machine['sysbus.model']
b = monitor.Machine.SystemBus
assert m.Transfers == 5 and m.Errors == 1
assert m.IRQ.IsSet == False
# Unknown register and read/write direction violations are explicit refusals.
for action in [lambda: m.ReadDoubleWord(0x6004),
               lambda: m.WriteDoubleWord(0x6000, 1),
               lambda: m.ReadDoubleWord(0x6068),
               lambda: m.ReadWord(0),
               lambda: m.WriteWord(0x10, 1),
               lambda: m.WriteDoubleWord(0x605c, 65536)]:
    refused = False
    try:
        action()
    except Exception:
        refused = True
    assert refused
m.Reset()
assert m.ReadDoubleWord(0) == 0 and m.ReadDoubleWord(0x6000) == 0
# Invalid destination and unsupported direction produce error, no DMA write.
m.WriteDoubleWord(0x605c, 4)
m.WriteDoubleWord(0x6060, 0x40021004)
m.WriteDoubleWord(0x6064, 0x100)
m.WriteDoubleWord(0x6058, 9)
m.Feed(42)
assert m.Transfers == 0 and m.Errors == 1
assert m.ReadDoubleWord(0x6000) == 0x80 and m.IRQ.IsSet
m.WriteDoubleWord(0x6004, 0)
assert m.ReadDoubleWord(0x6000) == 0x80
m.WriteDoubleWord(0x6004, 0x80)
assert m.ReadDoubleWord(0x6000) == 0 and not m.IRQ.IsSet
m.WriteDoubleWord(0x6064, 0x20000000)
m.WriteDoubleWord(0x6058, 0xc9)
m.Feed(42)
assert m.Transfers == 0 and m.Errors == 2
m.SetInput(0x1234)
assert b.ReadWord(0x40020010) == 0x1234
print('R610_PERIPHERAL_PASS')
