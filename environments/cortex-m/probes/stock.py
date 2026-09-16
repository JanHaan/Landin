# Runs inside Renode's IronPython, against the pinned stock models.
bus = monitor.Machine.SystemBus
uart = monitor.Machine['sysbus.uart']
dma = monitor.Machine['sysbus.dma']
bus.WriteDoubleWord(0x40020000, 1 << 6)
bus.WriteDoubleWord(0x40020018, 8)
assert bus.ReadDoubleWord(0x40020014) == 8
bus.WriteDoubleWord(0x40020018, 8 << 16)
assert bus.ReadDoubleWord(0x40020014) == 0
# UART reception without a running CPU: feed two bytes through DMA requests.
bus.WriteDoubleWord(0x4000440c, (1 << 13) | (1 << 2))
bus.WriteDoubleWord(0x40004414, 1 << 6)
bus.WriteDoubleWord(0x40026014, 2)
bus.WriteDoubleWord(0x40026018, 0x40004404)
bus.WriteDoubleWord(0x4002601c, 0x20000000)
bus.WriteDoubleWord(0x40026010, 1 | (1 << 4) | (1 << 8) | (1 << 10))
uart.WriteChar(65)
uart.WriteChar(66)
assert bus.ReadByte(0x20000000) == 65
assert bus.ReadByte(0x20000001) == 66
assert bus.ReadDoubleWord(0x40026014) == 0
assert bus.ReadDoubleWord(0x40026000) & 0x20
# CIRC is tagged, so NDT stays zero: the required reload is absent.
bus.WriteDoubleWord(0x40026008, 0x20)
assert bus.ReadDoubleWord(0x40026000) == 0
print('R610_STOCK_LIMIT_CONFIRMED')
