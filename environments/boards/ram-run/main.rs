//! Warm board entry. Deliberately has no flasher, reset, or erase operation.
//! The Python board tool owns the rig lock, USB guard and physical oracle.
use anyhow::{Context, Result, bail, ensure};
use clap::Parser;
use object::{Object, ObjectSection, ObjectSymbol};
use probe_rs::{
    Core, MemoryInterface, Permissions, RegisterId,
    config::{DebugSequence, Registry, Target},
    probe::{DebugProbeSelector, list::Lister},
};
use probe_rs::architecture::arm::sequences::DefaultArmSequence;
use probe_rs::architecture::riscv::{Abstractcs, Dmcontrol, Progbuf0, Progbuf1};
use probe_rs::architecture::riscv::communication_interface::AccessRegisterCommand;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{fs, path::PathBuf, time::{Duration, Instant}};

#[derive(Parser)]
struct Args {
    #[arg(long, required_unless_present = "describe")] plan: Option<PathBuf>,
    #[arg(long, required_unless_present = "describe")] output: Option<PathBuf>,
    #[arg(long, exclusive = true)] describe: bool,
    #[arg(long)] validate: bool,
}

#[derive(Deserialize)]
struct Plan {
    format_version: u32,
    board: String,
    mode: String,
    probe: String,
    elf: PathBuf,
}

#[derive(Deserialize)]
struct ReadPlan {
    format_version: u32,
    board: String,
    mode: String,
    probe: String,
    address: u64,
    count: u32,
}

fn validate_read(plan: &ReadPlan) -> Result<()> {
    ensure!(plan.format_version == 1 && plan.mode == "read", "expected format 1 read plan");
    chip(&plan.board)?;
    ensure!((1..=65536).contains(&plan.count), "read count must be 1 to 65536 words");
    ensure!(plan.address % 4 == 0, "word read address must be aligned to four bytes");
    let end = plan.address.checked_add(u64::from(plan.count) * 4).context("read address overflow")?;
    ensure!(plan.address <= u64::from(u32::MAX) && end <= 1u64 << 32,
        "word read must fit the 32-bit target address space");
    Ok(())
}

fn execute_read(plan: &ReadPlan) -> Result<Value> {
    // Callers validate before opening a probe. Readbacks include flash and
    // MMIO as well as SRAM; they never use warm-entry cleanup or reset.
    let target = attach_target(&plan.board).with_context(|| format!("{} select target", plan.board))?;
    let selector: DebugProbeSelector = plan.probe.parse().context("parse probe selector")?;
    let probe = Lister::new().open(selector).with_context(|| format!("{} open probe {}", plan.board, plan.probe))?;
    let mut session = probe.attach(target, Permissions::default())
        .with_context(|| format!("{} attach without reset", plan.board))?;
    let mut words = vec![0u32; plan.count as usize];
    session.core(0).context("select readback core 0")?.read_32(plan.address, &mut words)
        .with_context(|| format!("{} read {} words at {:#x}", plan.board, plan.count, plan.address))?;
    // Session attach/drop clear debug breakpoints and may briefly halt the
    // executing core. Truncation excludes the reset-held other RP core.
    // No explicit halt, reset, peripheral cleanup or memory write occurs.
    drop(session);
    Ok(json!({"format_version":1,"status":"passed","mode":"read","board":plan.board,
        "address":plan.address,"count":plan.count,"words":words,"flash_written":false,
        "debug_housekeeping":true,"core":0,"helper_source_sha256":source_digest()}))
}

struct Image {
    bytes: Vec<u8>,
    segments: Vec<(u64, Vec<u8>)>,
    entry: u32,
    vector: u32,
    stack: u32,
    arm: bool,
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

fn source_digest() -> String {
    digest(include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/bin/landin-ram-run.rs")))
}

fn chip(board: &str) -> Result<&'static str> {
    Ok(match board {
        "rp2040" => "RP2040",
        "rp2350" => "RP235x",
        "rp2350_hazard3" => "RP235x_riscv",
        "stm32h753" => "STM32H753ZITx",
        "esp32c3" => "esp32c3",
        "esp32c5" => "esp32c5",
        _ => bail!("unknown board {board}"),
    })
}

// Both warm loading and readback must fail rather than rescue-reset a chip
// when its debug connection is unavailable. At the pinned probe-rs revision,
// RP2040's only normal-connect customization is a rescue-DP fallback in
// debug_port_setup. The generic sequence retains its ordinary multidrop
// setup and core debug start, without that fallback or a vendor reset path.
fn attach_target(board: &str) -> Result<Target> {
    static PLUGINS: std::sync::Once = std::sync::Once::new();
    PLUGINS.call_once(probe_rs_espressif::register_plugin);
    let mut target = Registry::from_builtin_families().get_target_by_name(chip(board)?)?;
    target.cores.truncate(1);
    if board == "rp2040" {
        target.debug_sequence = DebugSequence::Arm(DefaultArmSequence::create());
    }
    Ok(target)
}

// Board-tool policy, checked independently of the compiler report. ESP C3
// IRAM is an instruction alias of SRAM; its descriptor intentionally says rx.
fn in_ram(board: &str, address: u64, size: u64) -> bool {
    let ranges: &[(u64, u64)] = match board {
        "rp2040" => &[(0x20000000, 0x20042000)],
        "rp2350" | "rp2350_hazard3" => &[(0x20000000, 0x20082000)],
        "stm32h753" => &[(0, 0x10000), (0x20000000, 0x20020000),
            (0x24000000, 0x24080000), (0x30000000, 0x30048000), (0x38000000, 0x38010000)],
        "esp32c3" => &[(0x40380000, 0x403a0000), (0x3fca0000, 0x3fcc8000)],
        "esp32c5" => &[(0x40800000, 0x4084e000)],
        _ => return false,
    };
    size > 0 && address.checked_add(size).is_some_and(|end|
        ranges.iter().any(|(lo, hi)| address >= *lo && end <= *hi))
}

fn c3_instruction_ram(board: &str, address: u64) -> bool {
    board == "esp32c3" && (0x40380000..0x403a0000).contains(&address)
}

fn validate_sram_access(board: &str, address: u64, size: u64, memory: u64) -> Result<()> {
    // ESP-IDF C3 Memory Types: the instruction bus permits only aligned
    // four-byte accesses. Validate both initialized and reserved storage
    // before opening a probe; never round a transfer into adjacent storage.
    if c3_instruction_ram(board, address) {
        ensure!(address % 4 == 0 && size % 4 == 0 && memory % 4 == 0,
            "C3 instruction SRAM segment {address:#x} requires aligned four-byte storage and transfers");
    }
    Ok(())
}

fn word(bytes: &[u8], at: usize) -> Result<u32> {
    Ok(u32::from_le_bytes(bytes.get(at..at + 4).context("truncated ELF word")?.try_into()?))
}

fn linked_symbol_section(section: object::SymbolSection) -> bool {
    matches!(section, object::SymbolSection::Section(_) | object::SymbolSection::Absolute)
}

fn image(plan: &Plan) -> Result<Image> {
    ensure!(plan.format_version == 1 && plan.mode == "ram", "expected format 1 RAM plan");
    chip(&plan.board)?;
    let bytes = fs::read(&plan.elf)?;
    ensure!(bytes.get(..6) == Some(b"\x7fELF\x01\x01"), "expected little-endian ELF32");
    let file = object::File::parse(bytes.as_slice())?;
    let arm = matches!(plan.board.as_str(), "rp2040" | "rp2350" | "stm32h753");
    ensure!(file.architecture() == if arm {object::Architecture::Arm} else {object::Architecture::Riscv32},
        "ELF architecture does not match board");
    let symbol = |name: &str| -> Result<u32> {
        file.symbols().find(|s| s.name().ok() == Some(name) && linked_symbol_section(s.section()))
            .map(|s| s.address().try_into()).context(format!("missing {name}"))?
            .map_err(Into::into)
    };
    let vector = symbol("_landin_firmware_vectors")?;
    let table = file.section_by_name(".isr_vector").context("no vector section")?;
    let table_size = table.size();
    ensure!(table.address() == vector as u64 && table_size > 0 && table_size <= 4096,
        "vector symbol and section differ");
    ensure!(vector as u64 % table_size.next_power_of_two().max(128) == 0,
        "unaligned vector table");
    let stack = symbol("_landin_firmware_stack_top")?;
    let bottom = symbol("_landin_firmware_stack_bottom")?;
    ensure!(bottom < stack && in_ram(&plan.board, bottom.into(), (stack - bottom).into()), "stack is outside SRAM");
    ensure!(stack % if arm {8} else {16} == 0, "unaligned stack");
    let mut entry = if arm {symbol("_landin_firmware_reset")?} else {symbol("_landin_firmware_entry")?};
    let phoff = word(&bytes, 28)? as usize;
    let phsize = u16::from_le_bytes(bytes[42..44].try_into()?) as usize;
    let phcount = u16::from_le_bytes(bytes[44..46].try_into()?) as usize;
    ensure!(phsize >= 32 && phcount > 0 && phcount <= 128, "bad ELF program headers");
    let mut segments = Vec::new();
    let mut ranges = Vec::new();
    let mut loaded_sections = Vec::new();
    let mut executable = Vec::new();
    let mut table_loaded = false;
    for i in 0..phcount {
        let at = phoff.checked_add(i * phsize).context("ELF header overflow")?;
        if word(&bytes, at)? != 1 { continue; }
        let offset = word(&bytes, at + 4)? as usize;
        let address = word(&bytes, at + 8)? as u64;
        let physical = word(&bytes, at + 12)? as u64;
        let size = word(&bytes, at + 16)? as usize;
        let memory = word(&bytes, at + 20)? as u64;
        if memory == 0 { continue; }
        ensure!(physical == address && size as u64 <= memory && in_ram(&plan.board, address, memory),
            "segment at {address:#x} is not an in-place SRAM image; use the boot check");
        validate_sram_access(&plan.board, address, size as u64, memory)?;
        ensure!(address + memory <= bottom as u64 || address >= stack as u64,
            "segment overlaps reserved stack");
        ensure!(ranges.iter().all(|(lo,hi)| address + memory <= *lo || address >= *hi),
            "overlapping load segments");
        ranges.push((address, address + memory));
        loaded_sections.push((address, offset as u64, size as u64));
        if word(&bytes, at + 24)? & 1 != 0 {
            executable.push((address, address + size as u64));
        }
        let body = bytes.get(offset..offset.checked_add(size).context("segment overflow")?)
            .context("segment past end of ELF")?.to_vec();
        if vector as u64 >= address && (vector as u64) + table_size <= address + size as u64 {
            table_loaded = true;
        }
        if arm && table_loaded && vector as u64 >= address && (vector as u64) + 8 <= address + size as u64 {
            let position = (vector as u64 - address) as usize;
            ensure!(word(&body, position)? == stack, "vector stack differs from linked stack");
            entry = word(&body, position + 4)?;
            ensure!(entry & 1 == 1, "Arm entry is not Thumb");
        }
        segments.push((address, body));
    }
    // A custom script can exclude allocated sections from PT_LOAD with
    // :NONE, including NOLOAD BSS that startup will still clear. Validate
    // every allocated VMA independently of the loader's segment writes.
    for section in file.sections() {
        if section.size() == 0 || !matches!(section.flags(),
            object::SectionFlags::Elf { sh_flags, .. } if sh_flags.contains(object::elf::SHF_ALLOC)) {
            continue;
        }
        let address = section.address();
        let size = section.size();
        let name = section.name().context("invalid allocated section name")?;
        ensure!(in_ram(&plan.board, address, size),
            "allocated section {name} at {address:#x} is outside SRAM");
        ensure!(address + size <= bottom as u64 || address >= stack as u64,
            "allocated section {name} overlaps reserved stack");
        if let Some((offset, file_size)) = section.file_range() {
            // Match both the runtime span and its exact ELF file mapping.
            // Equal bytes at a different offset cannot substitute for the
            // initialized section the linker declared.
            ensure!(file_size == size && loaded_sections.iter().any(|(start, file_at, length)|
                address >= *start && address + size <= start + length
                && file_at.checked_add(address - start) == Some(offset)),
                "allocated section {name} has no matching file-backed load segment");
            ensure!(section.data().with_context(|| format!("read allocated section {name}"))?.len() as u64 == size,
                "allocated section {name} has truncated file data");
        }
    }
    // Symbols are what startup uses, so also reject script rebinding that
    // leaves an otherwise valid .bss section behind at its original VMA.
    for item in file.symbols() {
        let Ok(name) = item.name() else { continue; };
        if !linked_symbol_section(item.section()) || !name.starts_with("_landin_firmware_")
            || !(name.ends_with("_bss_start") || name.ends_with("_bss_end")) {
            continue;
        }
        let stem = name.strip_suffix("_start").or_else(|| name.strip_suffix("_end")).unwrap();
        let first = u64::from(symbol(&format!("{stem}_start"))?);
        let end = u64::from(symbol(&format!("{stem}_end"))?);
        ensure!(end >= first, "BSS symbol range {stem} ends before it starts");
        if end != first {
            ensure!(in_ram(&plan.board, first, end - first),
                "BSS symbol range {stem} is outside SRAM");
            ensure!(end <= bottom as u64 || first >= stack as u64,
                "BSS symbol range {stem} overlaps reserved stack");
        }
    }
    ensure!(!segments.is_empty() && table_loaded && in_ram(&plan.board, vector.into(), table_size),
        "vector table is not completely loaded in SRAM");
    let code = (entry & if arm {!1} else {!0}) as u64;
    ensure!(executable.iter().any(|(lo,hi)| code >= *lo && code < *hi), "entry is not loaded executable code");
    Ok(Image { bytes, segments, entry, vector, stack, arm })
}

fn poll(core: &mut Core<'_>, address: u64, mask: u32, expected: u32) -> Result<u32> {
    let until = Instant::now() + Duration::from_secs(2);
    loop {
        let value = core.read_word_32(address)
            .with_context(|| format!("poll register {address:#x}"))?;
        if value & mask == expected { return Ok(value); }
        ensure!(Instant::now() < until, "register {address:#x} did not reach {expected:#x}");
    }
}

fn update(core: &mut Core<'_>, address: u64, clear: u32, set: u32) -> Result<()> {
    let previous = core.read_word_32(address)
        .with_context(|| format!("read register {address:#x} before update"))?;
    core.write_word_32(address, (previous & !clear) | set)
        .with_context(|| format!("write updated register {address:#x}"))?;
    Ok(())
}

fn hazard3_irq_reset_writes() -> impl Iterator<Item = (u16, u32)> {
    // pico-sdk 2.2.0 hardware/regs/rvcsr.h: MEICONTEXT resets to
    // 0x8000; MEIEA, MEIFA and MEIPRA reset to zero. Low write bits
    // select windows of sixteen IRQ bits or four priority nibbles.
    // RP2350 implements 52 external IRQs: four bit and thirteen priority windows.
    std::iter::once((0xbe5, 0x8000))
        .chain((0..4).flat_map(|window| [(0xbe0, window), (0xbe2, window)]))
        .chain((0..13).map(|window| (0xbe3, window)))
}

fn cleanup(core: &mut Core<'_>, board: &str, arm: bool) -> Result<Value> {
    if arm {
        // ARM DCRSR selector 20 combines CONTROL:FAULTMASK:BASEPRI:PRIMASK.
        // Keep interrupts masked while retiring an interrupted handler.
        core.write_core_reg(RegisterId(20), 1u32).with_context(|| format!("{board} cleanup write core register {:#x}", 20))?;
        let mut thread = false;
        let until = Instant::now() + Duration::from_secs(2);
        for _ in 0..16384 {
            if core.read_core_reg::<u32>(RegisterId(16)).with_context(|| format!("{board} cleanup read core register {:#x}", 16))? & 0x1ff == 0 { thread = true; break; }
            if Instant::now() >= until { break; }
            core.step().with_context(|| format!("{board} cleanup step active handler"))?;
        }
        ensure!(thread, "could not retire active exception; use the boot check");
        core.write_word_32(0xe000e010, 0).with_context(|| format!("{board} cleanup write MMIO {:#x}", 0xe000e010u64))?; // SysTick CTRL
        core.write_word_32(0xe000ed04, (1 << 25) | (1 << 27)).with_context(|| format!("{board} cleanup write MMIO {:#x}", 0xe000ed04u64))?; // pending SysTick/PendSV
        for offset in (0..32).step_by(4) {
            core.write_word_32(0xe000e180 + offset, u32::MAX).with_context(|| format!("{board} cleanup write MMIO {:#x}", 0xe000e180 + offset))?; // NVIC ICER
            core.write_word_32(0xe000e280 + offset, u32::MAX).with_context(|| format!("{board} cleanup write MMIO {:#x}", 0xe000e280 + offset))?; // NVIC ICPR
        }
    } else {
        let state = core.read_core_reg::<u32>(RegisterId(0x300)).with_context(|| format!("{board} cleanup read core register {:#x}", 0x300))?;
        core.write_core_reg(RegisterId(0x300), state & !8).with_context(|| format!("{board} cleanup write core register {:#x}", 0x300))?;
        if board == "esp32c5" {
            // CLIC mintstatus.MIL is read-only. A genuine mret restores it
            // from mcause.MPIL; clearing the threshold cannot retire it.
            let until = Instant::now() + Duration::from_secs(2);
            while core.read_core_reg::<u32>(RegisterId(0xfb1)).with_context(|| format!("{board} cleanup read core register {:#x}", 0xfb1))? & 0xff000000 != 0 {
                ensure!(Instant::now() < until, "active CLIC handler did not retire; use the boot check");
                core.step().with_context(|| format!("{board} cleanup step active handler"))?; // probe-rs steps with dcsr.stepie=0.
            }
        }
        core.write_core_reg(RegisterId(0x300), 0x1800u32).with_context(|| format!("{board} cleanup write core register {:#x}", 0x300))?; // mstatus: MPP=M, MIE=0
        // ESP32-C3 TRM v1.4 section 1.4.1 lists no mie CSR (0x304).
        // Its interrupt enables are MMIO, masked below with mstatus.MIE clear.
        if board != "esp32c3" {
            core.write_core_reg(RegisterId(0x304), 0u32)
                .with_context(|| format!("{board} cleanup write core register 0x304"))?;
        }
        if board == "rp2350_hazard3" {
            // Abandoning an external handler without mret leaves its
            // priority stack active. MEICONTEXT is writable, so reset it
            // and all IRQ windows while MIE/mie are clear, before SRAM writes.
            for (csr, value) in hazard3_irq_reset_writes() {
                core.write_core_reg(RegisterId(csr), value).with_context(|| format!("{board} cleanup write core register {:#x}", csr))?;
            }
        }
    }
    match board {
        "rp2040" | "rp2350" | "rp2350_hazard3" => {
            let rp2 = board != "rp2040";
            // pico-sdk 2.2.0 PSM_FRCE_OFF.PROC1: park the other processor
            // without resetting core 0 or executing the ROM.
            let psm = if rp2 {0x40018000} else {0x40010000};
            let other = if rp2 {1 << 24} else {1 << 16};
            update(core, psm + 4, 0, other)?;
            poll(core, psm + 0xc, other, 0)?;
            core.write_word_32(if rp2 {0x400d8000} else {0x40058000}, 0).with_context(|| format!("{board} cleanup write MMIO {:#x}", if rp2 {0x400d8000} else {0x40058000}))?;
            // The same peripherals bringup.peripherals releases: asserting
            // reset stops DMA before any SRAM contents are changed.
            update(core, if rp2 {0x40020000} else {0x4000c000}, 0,
                if rp2 {0x14800244} else {0x00600124})?;
        }
        "stm32h753" => {
            let supply = core.read_word_32(0x5802480c).with_context(|| format!("{board} cleanup read MMIO {:#x}", 0x5802480c))?;
            core.write_word_32(0x5802480c, (supply & !7) | 2).with_context(|| format!("{board} cleanup write MMIO {:#x}", 0x5802480c))?;
            poll(core, 0x58024804, 1 << 13, 1 << 13)?;
            ensure!(core.read_word_32(0xe000ed14).with_context(|| format!("{board} cleanup read MMIO {:#x}", 0xe000ed14u64))? & 0x30000 == 0,
                "warm STM32 contract requires disabled caches; use the boot check");
            ensure!(core.read_word_32(0x58024410).with_context(|| format!("{board} cleanup read MMIO {:#x}", 0x58024410))? & 0x38 == 0,
                "warm STM32 contract requires HSI system clock; use the boot check");
            core.write_word_32(0x40004800, 0).with_context(|| format!("{board} cleanup write MMIO {:#x}", 0x40004800))?; // USART3 CR1
            update(core, 0x40020010, 1, 0)?; // DMA1 stream 0 EN
            poll(core, 0x40020010, 1, 0)?;
            core.write_word_32(0x40020008, 0x3d).with_context(|| format!("{board} cleanup write MMIO {:#x}", 0x40020008))?; // stream 0 LIFCR
            core.write_word_32(0x40004808, 0).with_context(|| format!("{board} cleanup write MMIO {:#x}", 0x40004808))?; // USART3 CR3 DMA/IRQ
            core.write_word_32(0x40004820, 0x00121bdf).with_context(|| format!("{board} cleanup write MMIO {:#x}", 0x40004820))?; // USART3 ICR
        }
        "esp32c3" | "esp32c5" => {
            // probe-rs on_connect/on_halt disable all chip watchdogs.
            // Keep UART timing and USB Serial/JTAG clocks intact; mask the
            // application interrupt sources, then its own startup rebuilds
            // the UART FIFOs, interrupt matrix and system timer.
            core.write_word_32(0x6000000c, 0).with_context(|| format!("{board} cleanup write MMIO {:#x}", 0x6000000c))?;
            core.write_word_32(0x60000010, u32::MAX).with_context(|| format!("{board} cleanup write MMIO {:#x}", 0x60000010))?;
            let timer = if board == "esp32c3" {0x60023000} else {0x6000a000};
            core.write_word_32(timer + 0x64, 0).with_context(|| format!("{board} cleanup write MMIO {:#x}", timer + 0x64))?;
            core.write_word_32(timer + 0x6c, 7).with_context(|| format!("{board} cleanup write MMIO {:#x}", timer + 0x6c))?;
            update(core, timer, 0x01c00000, 0)?; // comparator work enables 0..2
            if board == "esp32c3" { core.write_word_32(0x600c2000 + 0x104, 0).with_context(|| format!("{board} cleanup write MMIO {:#x}", 0x600c2000 + 0x104))?; }
            else { core.write_core_reg(RegisterId(0x347), 0u32).with_context(|| format!("{board} cleanup write core register {:#x}", 0x347))?; }
        }
        _ => unreachable!(),
    }
    let mut report = json!({"contract":"warm-board-v1", "peripheral_sources_stopped":true,
        "other_core_parked":board.starts_with("rp"), "rom_reset":false});
    if board == "rp2350_hazard3" {
        report["hazard3_irq_state_reset"] = json!(true);
    }
    Ok(report)
}

fn instruction_fence(session: &mut probe_rs::Session) -> Result<()> {
    let mut interface = session.get_riscv_interface(0).context("select RISC-V fence interface")?;
    let control: Abstractcs = interface.read_dm_register()?;
    ensure!((control.0 >> 24) & 31 >= 2, "debug module needs two program-buffer words for instruction fence");
    let saved0: Progbuf0 = interface.read_dm_register()?;
    let saved1: Progbuf1 = interface.read_dm_register()?;
    let mut dm: Dmcontrol = interface.read_dm_register()?;
    dm.set_haltreq(false);
    dm.set_resumereq(false);
    dm.set_ackhavereset(false);
    interface.write_dm_register(dm)?;
    let result = (|| -> Result<()> {
        for opcode in [0x0330000f, 0x0000100f] { // fence rw,rw; fence.i
            interface.write_dm_register(Abstractcs(0x700))?;
            interface.write_dm_register(Progbuf0(opcode))?;
            interface.write_dm_register(Progbuf1(0x00100073))?; // ebreak
            interface.write_dm_register(AccessRegisterCommand(0x00241000))
                .with_context(|| format!("execute fence opcode {opcode:#010x}"))?;
            let until = Instant::now() + Duration::from_secs(1);
            loop {
                let status: Abstractcs = interface.read_dm_register()?;
                if status.0 & (1 << 12) == 0 {
                    ensure!(status.0 & 0x700 == 0, "instruction fence failed: abstractcs={:#x}", status.0);
                    break;
                }
                ensure!(Instant::now() < until, "instruction fence timed out");
            }
        }
        Ok(())
    })();
    // Restore the words as well as hardware state: probe-rs caches its own
    // program buffer and does not see these direct writes.
    interface.write_dm_register(saved0)?;
    interface.write_dm_register(saved1)?;
    result
}

fn execute(plan: &Plan, image: &Image) -> Result<Value> {
    let target = attach_target(&plan.board).with_context(|| format!("{} select target", plan.board))?;
    let selector: DebugProbeSelector = plan.probe.parse().context("parse probe selector")?;
    let probe = Lister::new().open(selector).with_context(|| format!("{} open probe {}", plan.board, plan.probe))?;
    // Expose only the executing core to Session, whose Drop otherwise tries
    // to halt the reset-held RP core 1 and can leave core 0 halted on failure.
    // PSM below parks core 1 independently before changing any SRAM.
    let mut session = probe.attach(target, Permissions::default())
        .with_context(|| format!("{} attach without reset", plan.board))?;
    session.core(0).context("select warm-load core 0")?.halt(Duration::from_secs(2))
        .with_context(|| format!("{} halt core 0", plan.board))?;
    let mut core = session.core(0).context("select warm-load core 0")?;
    let previous_pc: u32 = core.read_core_reg(core.program_counter().id)
        .with_context(|| format!("{} read previous PC", plan.board))?;
    let cleanup = cleanup(&mut core, &plan.board, image.arm)
        .with_context(|| format!("{} warm cleanup", plan.board))?;
    let mut written = Vec::new();
    for (address, body) in &image.segments {
        if body.is_empty() { continue; }
        let back = if c3_instruction_ram(&plan.board, *address) {
            // Offline validation guaranteed whole words. Explicit word I/O
            // avoids probe-rs's byte-width program-buffer loads and stores.
            let words: Vec<u32> = body.chunks_exact(4)
                .map(|bytes| u32::from_le_bytes(bytes.try_into().unwrap())).collect();
            core.write_32(*address, &words)
                .with_context(|| format!("{} write instruction SRAM segment {address:#x} ({} words)", plan.board, words.len()))?;
            let mut back = vec![0u32; words.len()];
            core.read_32(*address, &mut back)
                .with_context(|| format!("{} verify instruction SRAM segment {address:#x} ({} words)", plan.board, words.len()))?;
            back.into_iter().flat_map(u32::to_le_bytes).collect::<Vec<u8>>()
        } else {
            core.write_8(*address, body)
                .with_context(|| format!("{} write SRAM segment {address:#x} ({} bytes)", plan.board, body.len()))?;
            let mut back = vec![0; body.len()];
            core.read_8(*address, &mut back)
                .with_context(|| format!("{} verify SRAM segment {address:#x} ({} bytes)", plan.board, body.len()))?;
            back
        };
        ensure!(back == *body, "SRAM readback differs at {address:#x}");
        written.push(json!({"address":address,"bytes":body.len(),"sha256":digest(body)}));
    }
    drop(core);
    if !image.arm { instruction_fence(&mut session).with_context(|| format!("{} instruction fence", plan.board))?; }
    let mut core = session.core(0).context("select warm-load core 0")?;
    if image.arm {
        core.write_core_reg(RegisterId(16), 0x01000000u32).context("entry write xPSR register 16")?;
        core.write_core_reg(RegisterId(20), 1u32).context("entry write special register 20")?;
        core.write_word_32(0xe000ed08, image.vector).context("entry write VTOR 0xe000ed08")?;
    } else {
        core.write_core_reg(RegisterId(0x305), image.vector).context("entry write mtvec CSR 0x305")?;
    }
    core.write_core_reg(core.stack_pointer().id, image.stack).context("entry write stack pointer")?;
    core.write_core_reg(core.program_counter().id, image.entry & if image.arm {!1} else {!0})
        .context("entry write program counter")?;
    core.run().with_context(|| format!("{} resume loaded entry", plan.board))?;
    Ok(json!({"format_version":1,"status":"passed","mode":"warm","board":plan.board,
        "elf_sha256":digest(&image.bytes),"flash_written":false,"previous_pc":previous_pc,
        "entry":image.entry,"vector":image.vector,"stack":image.stack,"segments":written,
        "cleanup":cleanup,"helper_source_sha256":source_digest()}))
}

fn process_plan(bytes: &[u8], validate: bool) -> Result<Value> {
    let envelope: Value = serde_json::from_slice(bytes)?;
    let read = envelope.get("mode").and_then(Value::as_str) == Some("read");
    if read {
        let plan: ReadPlan = serde_json::from_slice(bytes)?;
        validate_read(&plan)?; // Validate every input before opening a probe.
        if validate {
            Ok(json!({"format_version":1,"status":"validated","mode":"read","board":plan.board,
                "address":plan.address,"count":plan.count,"flash_written":false,
                "helper_source_sha256":source_digest()}))
        } else { execute_read(&plan) }
    } else {
        let plan: Plan = serde_json::from_slice(bytes)?;
        let image = image(&plan)?;
        if validate {
            Ok(json!({"format_version":1,"status":"validated","mode":"ram","board":plan.board,
                "elf_sha256":digest(&image.bytes),"entry":image.entry,"vector":image.vector,
                "stack":image.stack,"flash_written":false,"helper_source_sha256":source_digest()}))
        } else { execute(&plan, &image) }
    }
}

fn main() -> Result<()> {
    let args = Args::parse();
    if args.describe {
        println!("{}", json!({"protocol_version":1,"source_sha256":source_digest(),
            "probe_rs_revision":"6f9946fe748edd0e55604dc42bc0f7ea3e7485da"}));
        return Ok(());
    }
    let bytes = fs::read(args.plan.context("missing plan")?)?;
    let result = process_plan(&bytes, args.validate);
    let mode = if args.validate { "validate" }
        else if serde_json::from_slice::<Value>(&bytes).is_ok_and(|plan|
            plan.get("mode").and_then(Value::as_str) == Some("read")) { "read" }
        else { "warm" };
    fs::write(args.output.context("missing output")?, serde_json::to_vec_pretty(&match &result {
        Ok(value) => value.clone(),
        Err(error) => json!({"status":"failed","mode":mode,
            "flash_written":false,"error":format!("{error:#}")}),
    })?)?;
    result.map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hazard3_reset_clears_all_52_irqs_and_active_priority() {
        let mut enables = u64::MAX;
        let mut forced = u64::MAX;
        let mut priorities = [15u8; 52];
        let mut context = 0xff1f1fffu32; // active priority and interrupt context
        let writes: Vec<_> = hazard3_irq_reset_writes().collect();
        assert_eq!(writes.first(), Some(&(0xbe5, 0x8000)));
        assert_eq!(writes.last(), Some(&(0xbe3, 12))); // IRQs 48..51
        assert_eq!(writes.len(), 22);
        for (csr, value) in writes {
            match csr {
                0xbe5 => context = value,
                0xbe0 | 0xbe2 => {
                    assert!(value & 31 < 4);
                    assert_eq!(value >> 16, 0);
                    let mask = 0xffffu64 << (16 * (value & 31));
                    if csr == 0xbe0 { enables &= !mask; } else { forced &= !mask; }
                }
                0xbe3 => {
                    assert_eq!(value >> 16, 0);
                    let first = 4 * (value & 31) as usize;
                    priorities[first..first + 4].fill(0);
                }
                _ => panic!("unexpected Hazard3 CSR {csr:#x}"),
            }
        }
        assert_eq!(context, 0x8000);
        assert_eq!(enables, 0);
        assert_eq!(forced, 0);
        assert!(priorities.iter().all(|priority| *priority == 0));
    }
    #[test]
    fn describe_is_offline_and_excludes_execution_plans() {
        assert!(Args::try_parse_from(["helper", "--describe"]).unwrap().describe);
        assert!(Args::try_parse_from(["helper"]).is_err());
        assert!(Args::try_parse_from(["helper", "--plan", "p", "--output", "o"]).is_ok());
        assert!(Args::try_parse_from(["helper", "--describe", "--plan", "p", "--output", "o"]).is_err());
        assert!(Args::try_parse_from(["helper", "--describe", "--validate"]).is_err());
        assert!(Args::try_parse_from(["helper", "--validate"]).is_err());
        assert!(Args::try_parse_from(["helper", "--validate", "--plan", "p"]).is_err());
        assert!(Args::try_parse_from(["helper", "--validate", "--plan", "p", "--output", "o"]).unwrap().validate);
        assert_eq!(source_digest().len(), 64);
    }
    #[test]
    fn linker_absolute_and_section_symbols_are_defined_addresses() {
        use object::SymbolSection;
        assert!(linked_symbol_section(SymbolSection::Absolute));
        assert!(linked_symbol_section(SymbolSection::Section(object::SectionIndex(1))));
        for section in [SymbolSection::Undefined, SymbolSection::Common,
                        SymbolSection::Unknown, SymbolSection::None] {
            assert!(!linked_symbol_section(section));
        }
    }
    #[test]
    fn offline_read_validation_never_parses_or_opens_the_probe() {
        let mut plan = json!({"format_version":1,"board":"rp2040","mode":"read",
            "probe":"deliberately invalid probe selector","address":0x20000000u32,"count":1});
        let report = process_plan(&serde_json::to_vec(&plan).unwrap(), true).unwrap();
        assert_eq!(report["status"], "validated");
        assert_eq!(report["board"], "rp2040");
        assert_eq!(report["address"], 0x20000000u32);
        assert_eq!(report["helper_source_sha256"], source_digest());
        plan["count"] = json!(0);
        assert!(process_plan(&serde_json::to_vec(&plan).unwrap(), true).is_err());
    }
    fn read_plan(address: u64, count: u32) -> ReadPlan {
        ReadPlan { format_version: 1, board: "rp2040".into(), mode: "read".into(),
            probe: "0000:0002:10.42.0.50/0".into(), address, count }
    }
    #[test]
    fn attach_policy_keeps_one_core_and_avoids_rp2040_rescue_sequence() {
        for board in ["rp2040", "rp2350", "rp2350_hazard3", "stm32h753", "esp32c3", "esp32c5"] {
            let target = attach_target(board).unwrap();
            assert_eq!(target.cores.len(), 1);
            if board == "rp2040" {
                assert!(format!("{:?}", target.debug_sequence).contains("DefaultArmSequence"));
            }
        }
    }
    #[test]
    fn read_plans_need_no_elf_and_cover_flash_sram_and_mmio() {
        let plan: ReadPlan = serde_json::from_value(json!({"format_version":1,"board":"rp2040",
            "mode":"read","probe":"0000:0002:10.42.0.50/0","address":0x10000000u64,"count":64})).unwrap();
        assert!(validate_read(&plan).is_ok());
        for address in [0x20000000, 0x50000008, 0xe000ed08, 0xfffffffc] {
            assert!(validate_read(&read_plan(address, 1)).is_ok());
        }
        assert!(validate_read(&read_plan(0x20000000, 65536)).is_ok());
    }
    #[test]
    fn invalid_reads_are_refused_before_probe_access() {
        for (address, count) in [(0, 0), (0, 65537), (1, 1), (0x100000000, 1),
                                  (0xfffffffc, 2), (u64::MAX - 3, 2)] {
            assert!(validate_read(&read_plan(address, count)).is_err());
        }
        let mut plan = read_plan(0x20000000, 1);
        plan.board = "unknown".into();
        assert!(validate_read(&plan).is_err());
        plan.board = "rp2040".into();
        plan.mode = "ram".into();
        assert!(validate_read(&plan).is_err());
        plan.mode = "read".into();
        plan.format_version = 2;
        assert!(validate_read(&plan).is_err());
        for count in [json!(-1), json!(4294967296u64), Value::Null] {
            let invalid = json!({"format_version":1,"board":"rp2040","mode":"read",
                "probe":"0000:0002:10.42.0.50/0","address":0x20000000u64,"count":count});
            assert!(serde_json::from_value::<ReadPlan>(invalid).is_err());
        }
    }
    #[test]
    fn flash_and_wrapping_loads_are_refused_for_every_board() {
        for board in ["rp2040","rp2350","rp2350_hazard3","stm32h753","esp32c3","esp32c5"] {
            assert!(!in_ram(board, 0x10000000, 4));
            assert!(!in_ram(board, u64::MAX - 1, 4));
            assert!(!in_ram(board, 0x40000000, 4));
        }
    }
    fn elf_test_word(bytes: &mut [u8], at: usize, value: u32) {
        bytes[at..at + 4].copy_from_slice(&value.to_le_bytes());
    }
    // A real ELF32 image with one executable PT_LOAD, an allocated BSS
    // excluded from it (the linker-script :NONE case), and nonalloc metadata.
    fn allocated_test_elf() -> Vec<u8> {
        let mut bytes = vec![0u8; 0x700];
        bytes[..7].copy_from_slice(b"\x7fELF\x01\x01\x01");
        bytes[16..20].copy_from_slice(&[2, 0, 40, 0]); // ET_EXEC, EM_ARM
        for (at, value) in [(20, 1), (24, 0x200000c1), (28, 52), (32, 0x500)] {
            elf_test_word(&mut bytes, at, value);
        }
        for (at, value) in [(40, 52u16), (42, 32), (44, 1), (46, 40), (48, 7), (50, 4)] {
            bytes[at..at + 2].copy_from_slice(&value.to_le_bytes());
        }
        for (index, value) in [1, 0x100, 0x20000000, 0x20000000, 0xc4, 0xc4, 5, 4].into_iter().enumerate() {
            elf_test_word(&mut bytes, 52 + 4 * index, value);
        }
        elf_test_word(&mut bytes, 0x100, 0x20042000);
        elf_test_word(&mut bytes, 0x104, 0x200000c1);
        bytes[0x1c0..0x1c4].copy_from_slice(&[0x70, 0x47, 0x00, 0xbf]);
        let names = ["", ".isr_vector", ".text", ".bss", ".shstrtab", ".strtab", ".symtab"];
        let mut strings = vec![0u8];
        let mut offsets = Vec::new();
        for name in names {
            offsets.push(strings.len() as u32);
            strings.extend_from_slice(name.as_bytes()); strings.push(0);
        }
        bytes[0x200..0x200 + strings.len()].copy_from_slice(&strings);
        let sections = [
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [offsets[1], 1, 2, 0x20000000, 0x100, 0xc0, 0, 0, 256, 0],
            [offsets[2], 1, 6, 0x200000c0, 0x1c0, 4, 0, 0, 2, 0],
            [offsets[3], 8, 3, 0x20000200, 0, 16, 0, 0, 4, 0],
            [offsets[4], 3, 0, 0, 0x200, strings.len() as u32, 0, 0, 1, 0],
            [offsets[5], 3, 0, 0, 0x300, 0, 0, 0, 1, 0],
            [offsets[6], 2, 0, 0, 0x400, 7 * 16, 5, 1, 4, 16],
        ];
        for (index, section) in sections.into_iter().enumerate() {
            for (field, value) in section.into_iter().enumerate() {
                elf_test_word(&mut bytes, 0x500 + index * 40 + field * 4, value);
            }
        }
        let symbols = [
            ("_landin_firmware_vectors", 0x20000000, 1u16),
            ("_landin_firmware_stack_top", 0x20042000, 0xfff1),
            ("_landin_firmware_stack_bottom", 0x20041000, 0xfff1),
            ("_landin_firmware_reset", 0x200000c1, 2),
            ("_landin_firmware_bss_start", 0x20000200, 3),
            ("_landin_firmware_bss_end", 0x20000210, 3),
        ];
        let mut strings = vec![0u8];
        for (index, (name, value, section)) in symbols.into_iter().enumerate() {
            let at = 0x400 + (index + 1) * 16;
            elf_test_word(&mut bytes, at, strings.len() as u32);
            elf_test_word(&mut bytes, at + 4, value);
            bytes[at + 12] = 0x10; // STB_GLOBAL
            bytes[at + 14..at + 16].copy_from_slice(&section.to_le_bytes());
            strings.extend_from_slice(name.as_bytes()); strings.push(0);
        }
        bytes[0x300..0x300 + strings.len()].copy_from_slice(&strings);
        elf_test_word(&mut bytes, 0x500 + 5 * 40 + 20, strings.len() as u32);
        bytes
    }
    fn offline_elf_control(bytes: &[u8], validate: bool) -> Result<Value> {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!("landin-allocated-{}-{}.elf", std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)));
        fs::write(&path, bytes)?;
        let plan = serde_json::to_vec(&json!({"format_version":1,"board":"rp2040","mode":"ram",
            "probe":"deliberately invalid probe selector","elf":path}))?;
        let result = process_plan(&plan, validate);
        fs::remove_file(path)?;
        result
    }
    #[test]
    fn allocated_sections_and_startup_ranges_are_checked_before_probe_parsing() {
        let baseline = allocated_test_elf();
        assert_eq!(offline_elf_control(&baseline, true).unwrap()["status"], "validated");
        // Nonalloc ELF metadata and allocated SRAM NOBITS without a load
        // segment are valid. Rejected mutations each preserve the PT_LOAD.
        let cases: &[(&str, &[(usize, u32)])] = &[
            ("outside SRAM", &[(0x500 + 3 * 40 + 12, 0x10000000)]),
            ("overlaps reserved stack", &[(0x500 + 3 * 40 + 12, 0x20041000)]),
            ("outside SRAM", &[(0x500 + 3 * 40 + 12, 0xfffffff8)]),
            ("no matching file-backed load segment", &[(0x500 + 2 * 40 + 16, 0x1c4)]),
            ("no matching file-backed load segment", &[(0x500 + 2 * 40 + 12, 0x20000300)]),
            ("no matching file-backed load segment", &[(0x500 + 3 * 40 + 4, 1), (0x500 + 3 * 40 + 16, 0x200)]),
            ("BSS symbol range", &[(0x400 + 5 * 16 + 4, 0x10000000), (0x400 + 6 * 16 + 4, 0x10000010)]),
            ("BSS symbol range", &[(0x400 + 5 * 16 + 4, 0x20041000), (0x400 + 6 * 16 + 4, 0x20041010)]),
            ("ends before it starts", &[(0x400 + 6 * 16 + 4, 0x200001ff)]),
            ("missing _landin_firmware_bss_end", &[(0x400 + 6 * 16 + 12, 0x10)]),
        ];
        for (message, mutations) in cases {
            let mut bytes = baseline.clone();
            for (at, value) in *mutations { elf_test_word(&mut bytes, *at, *value); }
            // validate=false would parse the invalid selector after image
            // validation. This error therefore proves the pre-attach guard.
            let error = format!("{:#}", offline_elf_control(&bytes, false).unwrap_err());
            assert!(error.contains(message), "wanted {message}, got {error}");
            assert!(!error.contains("parse probe selector"), "{error}");
        }
        let mut empty = baseline.clone();
        elf_test_word(&mut empty, 0x400 + 5 * 16 + 4, 0x10000000);
        elf_test_word(&mut empty, 0x400 + 6 * 16 + 4, 0x10000000);
        assert!(offline_elf_control(&empty, true).is_ok());
        // A minimal image need not define BSS endpoints at all.
        let mut absent = baseline.clone();
        elf_test_word(&mut absent, 0x400 + 5 * 16 + 12, 0x10);
        elf_test_word(&mut absent, 0x400 + 6 * 16 + 12, 0x10);
        assert!(offline_elf_control(&absent, true).is_ok());
    }
    #[test]
    fn c3_instruction_storage_requires_whole_aligned_words_before_io() {
        for (address, size, memory) in [(0x40380000, 4, 4),
                (0x40380180, 0x5b50, 0x5b50), (0x4039fffc, 4, 4),
                (0x40380200, 0, 16)] {
            assert!(c3_instruction_ram("esp32c3", address));
            assert!(validate_sram_access("esp32c3", address, size, memory).is_ok());
        }
        for (address, size, memory) in [(0x40380001, 4, 4),
                (0x40380000, 3, 4), (0x40380000, 4, 5),
                (0x40380002, 2, 2)] {
            assert!(validate_sram_access("esp32c3", address, size, memory).is_err());
        }
        assert!(!c3_instruction_ram("esp32c3", 0x3fca0000));
        assert!(!c3_instruction_ram("esp32c5", 0x40800000));
        assert!(validate_sram_access("esp32c3", 0x3fca0001, 3, 5).is_ok());
        assert!(validate_sram_access("esp32c5", 0x40800001, 3, 5).is_ok());
    }
    #[test]
    fn c3_aliases_have_disjoint_physical_storage() {
        assert!(in_ram("esp32c3",0x40380000,0x20000));
        assert!(in_ram("esp32c3",0x3fca0000,0x28000));
        assert!(!in_ram("esp32c3",0x3fc80000,4));
        assert!(!in_ram("esp32c3",0x4039ffff,2));
    }
}
