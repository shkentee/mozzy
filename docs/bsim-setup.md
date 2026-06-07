# BabbleSim (bsim) BLE Simulator Integration

> **Status**: Phase 5+ scaffold. The CI workflow (`.github/workflows/bsim.yml`)
> installs bsim and runs a Zephyr-shipped smoke test. Custom omi BLE tests go
> under `tests/bsim/` in Phase 6.

## What and why

[BabbleSim](https://babblesim.github.io) is a 2.4 GHz physical-layer simulator
that lets us run the **real** Zephyr Bluetooth Host + Controller stack against
a **simulated** radio. Multiple devices share a `bs_2G4_phy_v1` daemon over
UNIX sockets; everything is deterministic and runs on Linux without hardware.

For the wearable-recorder project, this lets us validate:

- Connection / pairing against the omi GATT services (audio / DFU / accel)
- Long-running chunk-push protocol behavior (the actual usefulness — we
  cannot exercise this on `native_sim` alone, which has no BLE radio)
- Reconnect scenarios + MTU negotiation against a known-good central

without burning real-device time.

## Scope split

| Layer | Where |
|---|---|
| BLE Host + Controller | Zephyr (already vendored via NCS) |
| Radio physical layer | bsim (`bs_2G4_phy_v1`) |
| GATT services under test | omi (`third_party/omi/...`) — unchanged |
| Test scripts (per scenario) | `tests/bsim/` in this repo (Phase 6) |
| CI orchestration | `.github/workflows/bsim.yml` (manual trigger) |

## CI workflow design

`bsim.yml` is **separate from `build.yml`** and **manually triggered**
(`workflow_dispatch`) for two reasons:

1. Building bsim from source takes ~5 min — we don't want that on every push
   while the main CI must stay fast.
2. The smoke test is fragile during the install phase (apt pinning, manifest
   churn). Failures shouldn't block normal merges.

The workflow:

1. Pulls deps via apt (`libsdl2-dev`, `libfftw3-dev`, `cmake`,
   `gcc-multilib`, etc.)
2. Clones `bsim_west`, runs `west update` + `make -f
   components/common/Makefile everything`
3. Smoke-tests the install by invoking `-help` on each shipped bsim
   binary (`bs_2G4_phy_v1`, `bs_device_handbrake`, etc.)

A green run proves the install + execution loop works. We can flip the
trigger to `push` later once it's stable.

> **Why only `-help` smoke?** Compiling a Zephyr-bundled bsim test under
> NCS pulls in `nrfxlib/softdevice_controller`, which CMake-rejects the
> `nrf52_bsim` SoC + float ABI combo. Picking the right controller
> (`CONFIG_BT_LL_SW_SPLIT=y`, suppressing the SoftDevice for this
> target) is Phase 6 plumbing — see `tests/bsim/wr_*/` once it lands.

## Board target

NCS v2.7 (Zephyr v3.6) → use board **`nrf52_bsim`**.
The hwmv2 form `native_sim/native/64/bt_ll_sw_split` is canonical from
Zephyr 3.7+ (NCS v2.8+) — defer that switch to whenever we upgrade NCS.

## Adding a new bsim test (Phase 6)

```
tests/bsim/wr_<scenario>/
├── test.cpp              # bs_args + Zephyr test_main entry
├── prj.conf              # Bluetooth host config + scenario flags
├── CMakeLists.txt
└── test_scripts/
    ├── _compile.sh       # wraps west build
    └── run_tests.sh      # spawns devices + phy + verdicts
```

Use `${ZEPHYR_BASE}/tests/bsim/bluetooth/host/adv/encrypted/css_sample_data/`
as the working template — it's the smallest GATT-touching test that exercises
both peripheral and central roles end-to-end.

## Local execution (developer machine)

```bash
# One-off install (mirror of CI steps)
sudo apt-get install -y libsdl2-dev libfftw3-dev pkg-config
mkdir -p /opt/bsim && cd /opt/bsim
git clone https://github.com/BabbleSim/babblesim-manifest.git .west/manifest
west init -l .west/manifest
west update
make everything -j$(nproc)

# Per-test cycle
export BSIM_OUT_PATH=/opt/bsim
export BSIM_COMPONENTS_PATH=/opt/bsim/components
export ZEPHYR_BASE=/path/to/ncs/zephyr
${ZEPHYR_BASE}/tests/bsim/bluetooth/host/adv/encrypted/css_sample_data/test_scripts/_compile.sh
${ZEPHYR_BASE}/tests/bsim/bluetooth/host/adv/encrypted/css_sample_data/test_scripts/run_tests.sh
```

## Caching note

`make everything` rebuilds ~150 .o files. For repeat runs on the same runner,
cache `/opt/bsim` via `actions/cache` keyed on the manifest commit. Skipped
for now to keep the workflow definition simple — revisit if total runtime
becomes a problem.
