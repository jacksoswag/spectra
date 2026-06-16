# Test 4 — WindowServer injection feasibility (EMPIRICAL)

**Machine:** MacBook Air M3 (Mac15,12), macOS 26.5.1 (build 25F80), Darwin 25.5.0.
**Protections:** SIP **disabled**, Authenticated-Root **disabled**, `boot-args = -arm64e_preview_abi` (note: `amfi_get_out_of_my_way` is **not** set).
**Verdict: NOT FEASIBLE.** Confirmed empirically, not from literature.

## What was run

`probe.c` (this dir): finds WindowServer/Dock/loginwindow, calls `task_for_pid` on each
plus a control process, and tries the `processor_set_tasks` enumeration path. Run twice:
once unsigned, once ad-hoc-signed with `com.apple.security.cs.debugger` +
`get-task-allow` + `disable-library-validation` (`debugger.entitlements`). Corroborated
with Apple's own debugger-entitled `vmmap`.

## Results

| Target | Kind | `task_for_pid` (debugger-entitled, SIP off) | `vmmap` |
|--------|------|---------------------------------------------|---------|
| **WindowServer** (pid 171) | Apple platform binary, library-validation | **DENIED (kr=5, KERN_FAILURE)** | **DENIED (rc=255)** |
| Dock (pid 402) | Apple platform binary | **SUCCESS — full control port (0xa03), task_info OK** | n/a |
| self-compiled `get-task-allow` binary | non-platform | SUCCESS — mappable | SUCCESS |
| `/bin/sleep` child | Apple platform binary | denied | n/a |

Unsigned (no entitlement) run: every `task_for_pid` denied (generic non-root restriction).
`processor_set_tasks` path: `host_processor_set_priv` needs root/host_priv, denied as user.

## Why this settles it

1. **`task_for_pid` is the precondition for everything** in item 4 (dylib injection via
   thread-hijack, memory inspection of compositing IOSurfaces, render-path interposition).
   No task port ⇒ none of it is possible.
2. The denial is **not** because of SIP or because we lack root. A `com.apple.security.cs.debugger`
   process on a SIP-disabled machine successfully took Dock's task port in the same run.
   WindowServer is denied by the kernel's platform-binary task-conversion check
   (`task_conversion_eval`), which is independent of SIP and of AMFI dylib-loading policy.
3. **`amfi_get_out_of_my_way` would not change this.** AMFI governs *code-signing / dylib
   loading*; the task-port denial happens before any dylib question. (Setting that boot-arg
   was deliberately NOT done — it requires a reboot and was out of scope for an unattended run.)
4. WindowServer's signature shows `library-validation` + platform identifier, so even if a
   task port existed, only Apple-signed code could load — and a fault in the compositor
   freezes the whole UI session.

## The one thing SIP-off *does* buy (relevant to Test 3)

Dock.app is reachable with a debugger entitlement. This is exactly the **yabai foothold**:
you inject into Dock (which holds the client connection to WindowServer), never into
WindowServer itself. Confirmed live here. See `../03_per_app_injection`.

## Residual theoretical vectors (not pursued — unmaintainable / destructive)

- Authenticated-root is off, so the system volume is writable; one could in principle
  replace WindowServer/SkyLight on disk and re-bless. This breaks on every OS update,
  risks an unbootable system, and is the opposite of "maintainable." Not done.
- A kernel/WindowServer memory-corruption exploit (cf. Pwn2Own 2018) would grant in-process
  execution. That is an exploit, not an API. Not pursued.
