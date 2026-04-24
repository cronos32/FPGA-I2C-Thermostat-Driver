# I2C Debug Session — Test Plan & Branch Summary

Short living doc for the FPGA bench session. Goal: get a real temperature
reading from the ADT7420 on `TMP_SDA` / `TMP_SCL` (Nexys A7) instead of
`0xFF 0xFF`, and fix the "S vs Sr" labeling on the scope decoder.

Bring **all four branches** to the session pre-synthesised (bitstreams on a
USB stick) so you don't waste the 2-hour slot in Vivado.

---

## Branch map — which bitstream does what

| Branch | Based on | What's in it | Purpose |
|---|---|---|---|
| `main` | — | Original broken baseline | Reference only — do not flash |
| `testing_Sr` | `main` + e6afb1f + ac1976d | Original `adt7420_reader`; `i2c_controller` WRITING_ACK transition put back *inside* `if clock_flip='1'` (the bad `else` removed); `thermostat_top` connects `adt7420_reader` directly to `TMP_SDA`/`TMP_SCL`, debug header mirrors pin state via `'0' when TMP_SDA='0' else 'Z'` | **Build A** — minimal fix, keeps the pointer-write + Sr flow. If this works, you keep 16-bit mode support. |
| `testing_sr3` | `testing_Sr` + c43fa01 | Same as A + `resolution_16bit => '0'` in `thermostat_top` | **Build B** — rules out 16-bit/13-bit math as the cause of garbage data |
| `testing_i2c4` | `testing_sr3` + 718c4c5 | Same as B + new `adt7420_reader_simple.vhd` used instead of the full reader — no config write, no pointer write, no repeated START; just `S addr+R → MSB → LSB → P` | **Build C** — maximum simplicity. Eliminates every write/Sr code path |
| `testing_i2c5` ← **current** | `testing_i2c4` + 5cd51ec | Same as C + rewritten `i2c_controller`: added `WRITING_ACK_LOW` / `READING_ACK_LOW` states, SCL divider widened to 10 bits (~98 kHz), `clock_flip` reset explicitly in `WRITE_WAITING` / `READ_WAITING` | **Build D** — lowest risk. Bus parks at SCL=0 between bytes, no false-STOP risk |

Dead/abandoned branches (don't flash):
- `2-testing_Sr` — earlier dead-end Sr attempt (63df38d)

---

## What to check on the synthesized project before bitgen

Per-branch, open the Vivado project and confirm these *before* generating
the bitstream, so you don't walk in with a broken build:

### All branches
- [ ] `nexys.xdc` has `PULLUP true` on both `TMP_SDA` and `TMP_SCL`
- [ ] `j_sda` / `j_scl` pin constraints match the PMOD header you'll probe
- [ ] Top-level port list still has `TMP_SDA`, `TMP_SCL`, `j_sda`, `j_scl`
      all declared `inout STD_LOGIC`
- [ ] No synthesis warnings about multi-driver nets on `TMP_SDA` or `TMP_SCL`

### Branch-specific smoke checks
- **testing_Sr / testing_sr3** — `i2c_controller.vhd` WRITING_ACK: state
  transition is **inside** `if clock_flip = '1'`, no `else` branch, no
  comment `-- fix` left behind
- **testing_i2c4 / testing_i2c5** — `thermostat_top.vhd` instantiates
  `adt7420_reader_simple` (not `adt7420_reader`); no `resolution_16bit`
  port on the simple version
- **testing_i2c5** only — `i2c_controller.vhd`:
  - `i2c_clock_counter : UNSIGNED (9 downto 0)` (10 bits, not 7)
  - `running_clock <= i2c_clock_counter (9);`
  - State type includes `WRITING_ACK_LOW` and `READING_ACK_LOW`
  - `WRITE_WAITING` and `READ_WAITING` contain `clock_flip := '0';`

---

## Flash order and decision tree

Start with **Build D (testing_i2c5)** — highest likelihood of success.

```
 Flash D ──► scope shows S 4BR~a <MSB> <LSB> P with real bytes?
   │
   ├── YES → You're done. Confirm 7-seg display shows plausible temp.
   │
   └── NO ──► What's on the scope?
             │
             ├── Still 4BWa then nothing
             │   → FSM froze after 1st byte. Check counter is 10 bits and
             │     `running_clock` uses bit 9. Verify `busy_d` edge detect
             │     in the reader (simple reader uses the same pattern).
             │
             ├── S 4BR~a FF FF P (address ACKed, but data still all 1s)
             │   → Slave ACKs address but can't drive SDA during read.
             │     Most likely TMP_SDA is not a true IOBUF in synth.
             │     Open implemented design, find TMP_SDA net, confirm it
             │     routes to an IOBUF primitive (not OBUFT + IBUF split).
             │
             ├── Scope shows S 4BR with NAK on the address
             │   → Wrong slave address or sensor dead. Verify 0x4B on
             │     scope (96h = 10010110 for write, 97h for read).
             │     Try "1001000" (0x48) as a sanity test.
             │
             └── Nothing on scope at all (no SCL clocks)
                 → Reader FSM stuck in S_STARTUP or S_IDLE, or reset
                   held high. Probe error LED (led[0]) and check btnc.
 │
 ▼
 Fall back to Build C (testing_i2c4) — rules out the _ACK_LOW rework.
 If C works and D doesn't, bug is in the new i2c_controller states.
 │
 ▼
 Fall back to Build B (testing_sr3) — rules out the simplified reader.
 If B works and C/D don't, bug is in adt7420_reader_simple.
 │
 ▼
 Fall back to Build A (testing_Sr) — rules out both the simple reader
 and 13-bit mode.
 If none of A–D work, the problem is either in `i2c_controller`'s data
 path or the physical pin/pullup chain, not in the sequencer logic.
```

---

## Expected bus behavior per build

Assume room temperature ~22 °C, ADT7420 at address `0x4B`.

### Build A / B (pointer-write + Sr path)
```
 S  4BW~a  00~a  Sr 4BR~a  <MSB>~a  <LSB>~a  P
```
- `<MSB> <LSB>` in **16-bit mode (Build A)** ≈ `0x0B 0x00` (22.0 °C raw code = 352 << 4 = 0x1600, MSB=0x16 actually — recompute per reading)
- In **13-bit mode (Build B)** ≈ `0x0B 0x0X` where low 3 bits of LSB are status flags

### Build C / D (direct read, no pointer write)
```
 S  4BR~a  <MSB>~a  <LSB>~a  P
```
- 13-bit mode only. MSB ≈ `0x0B` for ~22 °C, LSB low 3 bits = flags.

### On the `temperature` output (`sig_temp_vector`)
- Tenths of a degree, signed. 22.5 °C → `225` → `0x00E1`
- At reset → `0x0000` until first `temp_valid` pulse (1 s after `btnc`)
- 7-seg should display `_XXXC` followed by `_YYYC` per half of the display

---

## Key invariants worth re-verifying in code

If anything misbehaves, cross-check these — they are the non-obvious bits
that previously caused regressions:

1. **`WRITING_ACK` / `READING_ACK` must issue the 9th SCL pulse.** The state
   transition can only fire on `clock_flip='1'` (SCL-high half) — never on
   `clock_flip='0'`, or the 9th clock gets truncated and the slave hangs.
   (This was the `else -- fix` regression on `testing_Sr`.)

2. **`TMP_SDA` / `TMP_SCL` must be connected to the reader via `inout`
   hierarchy — not through an intermediate `std_logic` signal.** An
   internal signal has no IOBUF, so `'Z'` loses its bidirectional meaning
   in synthesis and the slave can't drive data back.

3. **Debug-header mirrors must be tri-state-aware.** `j_sda <= TMP_SDA`
   synthesizes as a regular output driver (`'0'` or `'1'`), which fights
   the bus. Correct form:
   ```vhdl
   j_sda <= '0' when TMP_SDA = '0' else 'Z';
   ```

4. **Simplified reader assumes POR defaults.** ADT7420 on power-up is
   13-bit continuous conversion, pointer at `0x00`. If reset happens
   *after* a previous config write in the same power cycle, the pointer
   may not be at `0x00`. Power-cycle the board (not just `btnc`) between
   build swaps if the address ever changed.

5. **`clock_flip` must be `'0'` when entering `WRITING_DATA` /
   `READING_DATA`.** Otherwise the first bit is transmitted with SCL
   high, corrupting byte 0 of every write and misaligning reads.
   testing_i2c5 enforces this in `WRITE_WAITING` / `READ_WAITING`.

---

## Full list of changes from `main` → `testing_i2c5`

### `thermostat/thermostat.srcs/sources_1/new/i2c_controller.vhd`
- Removed `else` in `WRITING_ACK` (was skipping the 9th clock)
- Added `WRITING_ACK_LOW` state — drops SCL low, parks bus SCL=0 SDA=Z
- Added `READING_ACK_LOW` state — same for master-driven ACK/NAK
- `WRITING_ACK` / `READING_ACK` now *only* perform the SCL-high half
  (read ACK / drive ACK/NAK), then hand off to their `_LOW` companion
- `WRITE_WAITING` / `READ_WAITING` now explicitly `clock_flip := '0'`
- SCL divider widened: `UNSIGNED(7 downto 0)` → `UNSIGNED(9 downto 0)`,
  `running_clock <= bit(9)`. Frequency: ~390 kHz → ~98 kHz
- Header comment updated

### `thermostat/thermostat.srcs/sources_1/new/adt7420_reader_simple.vhd` (new file)
- 9-state FSM (vs 16 in the full reader)
- No config write, no pointer write, no repeated START
- Hardcoded 13-bit mode; no `resolution_16bit` port
- Reads `{MSB, LSB}` from pointer 0x00 (POR default); auto-increments
  to 0x01 for LSB
- 10 ms startup delay (covers sensor POR ≤1 ms); `READ_INTERVAL_MS=1000`
  guarantees first reading lands after the ~240 ms conversion

### `thermostat/thermostat.srcs/sources_1/new/thermostat_top.vhd`
- Removed intermediate `sig_sda` / `sig_scl` signals — these broke the
  IOBUF / tri-state chain
- Sensor reader now directly connects to top-level `TMP_SDA` / `TMP_SCL`
  ports
- Component swapped from `adt7420_reader` to `adt7420_reader_simple`
- `resolution_16bit` port removed from the component declaration and
  instantiation
- Debug header now mirrors the real bus voltage via
  `j_sda <= '0' when TMP_SDA = '0' else 'Z';` (and same for `j_scl`)

### `thermostat/thermostat.srcs/sources_1/new/adt7420_reader.vhd`
- Unchanged — kept as reference. Not instantiated on testing_i2c5.

---

## Scope captures for reference

- `img/scope_6.png`, `img/scope_7.png` — pre-regression behaviour on
  `testing_Sr` / earlier, showed `S 4BR FF FF` (desired transaction
  shape, wrong data — the original bug)
- `img/scope_8.png` — post-regression after the bad `else` fix: only
  `4BWa` then nothing
- `img/scope_9.png` — startup config write, partially captured, `4BWa
  07a` with error markers (truncated because of the same `else` bug)

Re-capture these after each build for the write-up.

---

## If nothing works

Definitive probe: put a scope probe **directly on the sensor pin** (not
the PMOD header). If SDA ever goes low during a read's data bits, the
sensor is talking and the problem is on the FPGA read-back path. If SDA
stays high, the sensor never responds and the problem is protocol/address
/config on the FPGA transmit path.

You can also short SDA to GND manually during a read: if the master ACKs
erratically but keeps clocking, the FSM flow is fine; if SCL freezes,
something is reacting to SDA incorrectly.

---

## Post-session

After you identify which build works, squash-merge that branch into a
fresh `i2c-fixed` branch off `main` so the history stays linear. The
other `testing_*` branches can stay as a debugging paper trail.
