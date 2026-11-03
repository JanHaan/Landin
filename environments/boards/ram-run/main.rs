//! Warm board entry. Deliberately has no flasher, reset, or erase operation.
//! The Python board tool owns the rig lock, USB guard and physical oracle.
use anyhow::{Context, Result, bail, ensure};
use clap::Parser;
use object::{Object, ObjectSection, ObjectSymbol};
use probe_rs::{Core, MemoryInterface, Permissions, RegisterId, config::Registry, probe::{DebugProbeSelector, list::Lister}};
use probe_rs::architecture::riscv::{Abstractcs, Dmcontrol, Progbuf0, Progbuf1};
use probe_rs::architecture::riscv::communication_interface::AccessRegisterCommand;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{fs, path::PathBuf, time::{Duration, Instant}};

#[derive(Parser)]
struct Args {
    #[arg(long)] plan: PathBuf,
    #[arg(long)] output: PathBuf,
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
    let selector: DebugProbeSelector = plan.probe.parse()?;
    let probe = Lister::new().open(selector)?;
    let mut target = Registry::from_builtin_families().get_target_by_name(chip(&plan.board)?)?;
    target.cores.truncate(1);
    let mut session = probe.attach(target, Permissions::default())?;
    let mut words = vec![0u32; plan.count as usize];
    session.core(0)?.read_32(plan.address, &mut words)?;
    // Session attach/drop clear debug breakpoints and may briefly halt the
    // executing core. Truncation excludes the reset-held other RP core.
    // No explicit halt, reset, peripheral cleanup or memory write occurs.
    drop(session);
    Ok(json!({"format_version":1,"status":"passed","mode":"read","board":plan.board,
        "address":plan.address,"count":plan.count,"words":words,"flash_written":false,
        "debug_housekeeping":true,"core":0}))
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

fn word(bytes: &[u8], at: usize) -> Result<u32> {
    Ok(u32::from_le_bytes(bytes.get(at..at + 4).context("truncated ELF word")?.try_into()?))
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
        file.symbols().find(|s| s.name().ok() == Some(name) && s.is_definition())
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
        ensure!(address + memory <= bottom as u64 || address >= stack as u64,
            "segment overlaps reserved stack");
        ensure!(ranges.iter().all(|(lo,hi)| address + memory <= *lo || address >= *hi),
            "overlapping load segments");
        ranges.push((address, address + memory));
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
    ensure!(!segments.is_empty() && table_loaded && in_ram(&plan.board, vector.into(), table_size),
        "vector table is not completely loaded in SRAM");
    let code = (entry & if arm {!1} else {!0}) as u64;
    ensure!(executable.iter().any(|(lo,hi)| code >= *lo && code < *hi), "entry is not loaded executable code");
    Ok(Image { bytes, segments, entry, vector, stack, arm })
}

fn poll(core: &mut Core<'_>, address: u64, mask: u32, expected: u32) -> Result<u32> {
    let until = Instant::now() + Duration::from_secs(2);
    loop {
        let value = core.read_word_32(address)?;
        if value & mask == expected { return Ok(value); }
        ensure!(Instant::now() < until, "register {address:#x} did not reach {expected:#x}");
    }
}

fn update(core: &mut Core<'_>, address: u64, clear: u32, set: u32) -> Result<()> {
    let previous = core.read_word_32(address)?;
    core.write_word_32(address, (previous & !clear) | set)?;
    Ok(())
}

fn cleanup(core: &mut Core<'_>, board: &str, arm: bool) -> Result<Value> {
    if arm {
        // ARM DCRSR selector 20 combines CONTROL:FAULTMASK:BASEPRI:PRIMASK.
        // Keep interrupts masked while retiring an interrupted handler.
        core.write_core_reg(RegisterId(20), 1u32)?;
        let mut thread = false;
        let until = Instant::now() + Duration::from_secs(2);
        for _ in 0..16384 {
            if core.read_core_reg::<u32>(RegisterId(16))? & 0x1ff == 0 { thread = true; break; }
            if Instant::now() >= until { break; }
            core.step()?;
        }
        ensure!(thread, "could not retire active exception; use the boot check");
        core.write_word_32(0xe000e010, 0)?; // SysTick CTRL
        core.write_word_32(0xe000ed04, (1 << 25) | (1 << 27))?; // pending SysTick/PendSV
        for offset in (0..32).step_by(4) {
            core.write_word_32(0xe000e180 + offset, u32::MAX)?; // NVIC ICER
            core.write_word_32(0xe000e280 + offset, u32::MAX)?; // NVIC ICPR
        }
    } else {
        let state = core.read_core_reg::<u32>(RegisterId(0x300))?;
        core.write_core_reg(RegisterId(0x300), state & !8)?;
        if board == "esp32c5" {
            // CLIC mintstatus.MIL is read-only. A genuine mret restores it
            // from mcause.MPIL; clearing the threshold cannot retire it.
            let until = Instant::now() + Duration::from_secs(2);
            while core.read_core_reg::<u32>(RegisterId(0xfb1))? & 0xff000000 != 0 {
                ensure!(Instant::now() < until, "active CLIC handler did not retire; use the boot check");
                core.step()?; // probe-rs steps with dcsr.stepie=0.
            }
        }
        core.write_core_reg(RegisterId(0x300), 0x1800u32)?; // mstatus: MPP=M, MIE=0
        core.write_core_reg(RegisterId(0x304), 0u32)?; // mie
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
            core.write_word_32(if rp2 {0x400d8000} else {0x40058000}, 0)?;
            // The same peripherals bringup.peripherals releases: asserting
            // reset stops DMA before any SRAM contents are changed.
            update(core, if rp2 {0x40020000} else {0x4000c000}, 0,
                if rp2 {0x14800244} else {0x00600124})?;
        }
        "stm32h753" => {
            let supply = core.read_word_32(0x5802480c)?;
            core.write_word_32(0x5802480c, (supply & !7) | 2)?;
            poll(core, 0x58024804, 1 << 13, 1 << 13)?;
            ensure!(core.read_word_32(0xe000ed14)? & 0x30000 == 0,
                "warm STM32 contract requires disabled caches; use the boot check");
            ensure!(core.read_word_32(0x58024410)? & 0x38 == 0,
                "warm STM32 contract requires HSI system clock; use the boot check");
            core.write_word_32(0x40004800, 0)?; // USART3 CR1
            update(core, 0x40020010, 1, 0)?; // DMA1 stream 0 EN
            poll(core, 0x40020010, 1, 0)?;
            core.write_word_32(0x40020008, 0x3d)?; // stream 0 LIFCR
            core.write_word_32(0x40004808, 0)?; // USART3 CR3 DMA/IRQ
            core.write_word_32(0x40004820, 0x00121bdf)?; // USART3 ICR
        }
        "esp32c3" | "esp32c5" => {
            // probe-rs on_connect/on_halt disable all chip watchdogs.
            // Keep UART timing and USB Serial/JTAG clocks intact; mask the
            // application interrupt sources, then its own startup rebuilds
            // the UART FIFOs, interrupt matrix and system timer.
            core.write_word_32(0x6000000c, 0)?;
            core.write_word_32(0x60000010, u32::MAX)?;
            let timer = if board == "esp32c3" {0x60023000} else {0x6000a000};
            core.write_word_32(timer + 0x64, 0)?;
            core.write_word_32(timer + 0x6c, 7)?;
            update(core, timer, 0x01c00000, 0)?; // comparator work enables 0..2
            if board == "esp32c3" { core.write_word_32(0x600c2000 + 0x104, 0)?; }
            else { core.write_core_reg(RegisterId(0x347), 0u32)?; }
        }
        _ => unreachable!(),
    }
    Ok(json!({"contract":"warm-board-v1", "peripheral_sources_stopped":true,
        "other_core_parked":board.starts_with("rp"), "rom_reset":false}))
}

fn instruction_fence(session: &mut probe_rs::Session) -> Result<()> {
    let mut interface = session.get_riscv_interface(0)?;
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
            interface.write_dm_register(AccessRegisterCommand(0x00241000))?;
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
    let selector: DebugProbeSelector = plan.probe.parse()?;
    let probe = Lister::new().open(selector)?;
    // Expose only the executing core to Session, whose Drop otherwise tries
    // to halt the reset-held RP core 1 and can leave core 0 halted on failure.
    // PSM below parks core 1 independently before changing any SRAM.
    let mut target = Registry::from_builtin_families().get_target_by_name(chip(&plan.board)?)?;
    target.cores.truncate(1);
    let mut session = probe.attach(target, Permissions::default())?;
    session.core(0)?.halt(Duration::from_secs(2))?;
    let mut core = session.core(0)?;
    let previous_pc: u32 = core.read_core_reg(core.program_counter().id)?;
    let cleanup = cleanup(&mut core, &plan.board, image.arm)?;
    let mut written = Vec::new();
    for (address, body) in &image.segments {
        if body.is_empty() { continue; }
        core.write_8(*address, body)?;
        let mut back = vec![0; body.len()];
        core.read_8(*address, &mut back)?;
        ensure!(back == *body, "SRAM readback differs at {address:#x}");
        written.push(json!({"address":address,"bytes":body.len(),"sha256":digest(body)}));
    }
    drop(core);
    if !image.arm { instruction_fence(&mut session)?; }
    let mut core = session.core(0)?;
    if image.arm {
        core.write_core_reg(RegisterId(16), 0x01000000u32)?;
        core.write_core_reg(RegisterId(20), 1u32)?;
        core.write_word_32(0xe000ed08, image.vector)?;
    } else {
        core.write_core_reg(RegisterId(0x305), image.vector)?;
    }
    core.write_core_reg(core.stack_pointer().id, image.stack)?;
    core.write_core_reg(core.program_counter().id, image.entry & if image.arm {!1} else {!0})?;
    core.run()?;
    Ok(json!({"format_version":1,"status":"passed","mode":"warm","board":plan.board,
        "elf_sha256":digest(&image.bytes),"flash_written":false,"previous_pc":previous_pc,
        "entry":image.entry,"vector":image.vector,"stack":image.stack,"segments":written,
        "cleanup":cleanup}))
}

fn main() -> Result<()> {
    let args = Args::parse();
    let bytes = fs::read(args.plan)?;
    let envelope: Value = serde_json::from_slice(&bytes)?;
    let read = envelope.get("mode").and_then(Value::as_str) == Some("read");
    let result = if read {
        let plan: ReadPlan = serde_json::from_slice(&bytes)?;
        validate_read(&plan)?; // Validate every input before opening a probe.
        execute_read(&plan)
    } else {
        let plan: Plan = serde_json::from_slice(&bytes)?;
        let image = image(&plan)?;
        execute(&plan, &image)
    };
    fs::write(args.output, serde_json::to_vec_pretty(&match &result {
        Ok(value) => value.clone(),
        Err(error) => json!({"status":"failed","mode":if read {"read"} else {"warm"},
            "flash_written":false,"error":format!("{error:#}")}),
    })?)?;
    result.map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn read_plan(address: u64, count: u32) -> ReadPlan {
        ReadPlan { format_version: 1, board: "rp2040".into(), mode: "read".into(),
            probe: "0000:0002:10.42.0.50/0".into(), address, count }
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
    #[test]
    fn c3_aliases_have_disjoint_physical_storage() {
        assert!(in_ram("esp32c3",0x40380000,0x20000));
        assert!(in_ram("esp32c3",0x3fca0000,0x28000));
        assert!(!in_ram("esp32c3",0x3fc80000,4));
        assert!(!in_ram("esp32c3",0x4039ffff,2));
    }
}
