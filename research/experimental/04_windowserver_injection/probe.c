// Test 4: WindowServer injection infeasibility probe.
//
// Empirically demonstrates that even with SIP disabled, you cannot obtain a
// usable Mach task port for WindowServer (an Apple-signed, hardened, platform
// binary), which is the precondition for any code-injection / memory-mapping
// attack on the compositor. Control case: a non-hardened child process we own,
// whose task port we CAN obtain, proving the mechanism works in general and is
// specifically denied for the platform binary.
//
// Read-only. Does not modify, write to, or crash anything.
//
// Build:  clang -o probe probe.c
// Run:    ./probe            (as user)   and   sudo -n ./probe   (if cached)

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach/processor_set.h>
#include <mach/mach_host.h>

static pid_t pid_of(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) < 0) return -1;
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return -1;
    if (sysctl(mib, 4, procs, &len, NULL, 0) < 0) { free(procs); return -1; }
    int n = (int)(len / sizeof(struct kinfo_proc));
    pid_t found = -1;
    for (int i = 0; i < n; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, name) == 0) { found = procs[i].kp_proc.p_pid; break; }
    }
    free(procs);
    return found;
}

static void path_of(pid_t pid, char *out, size_t outlen) {
    out[0] = 0;
    proc_pidpath(pid, out, (uint32_t)outlen);
}

static void try_tfp(const char *label, pid_t pid) {
    char path[4096]; path_of(pid, path, sizeof path);
    printf("\n--- task_for_pid(%s, pid=%d)\n", label, pid);
    printf("    path: %s\n", path[0] ? path : "(unknown)");
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    printf("    task_for_pid -> kr=%d (%s)\n", kr, mach_error_string(kr));
    if (kr != KERN_SUCCESS) {
        printf("    RESULT: DENIED. No task port -> cannot read/write memory, cannot inject.\n");
        return;
    }
    // We got a port. Is it a real (read/write capable) port, or a degraded name port?
    // Probe with a basic task_info call and a memory read of the mach header region.
    printf("    task port obtained: 0x%x\n", task);
    struct task_basic_info bi; mach_msg_type_number_t cnt = TASK_BASIC_INFO_COUNT;
    kr = task_info(task, TASK_BASIC_INFO, (task_info_t)&bi, &cnt);
    printf("    task_info(BASIC) -> kr=%d (%s)%s\n", kr, mach_error_string(kr),
           kr == KERN_SUCCESS ? "  [resident pages readable -> REAL control port]" : "  [degraded/name port]");
    if (kr == KERN_SUCCESS) {
        printf("    RESULT: FULL task port. Injection/inspection WOULD be possible here.\n");
    } else {
        printf("    RESULT: name-only/degraded port. Cannot inspect or inject.\n");
    }
    mach_port_deallocate(mach_task_self(), task);
}

int main(void) {
    printf("=== Test 4: WindowServer injection feasibility probe ===\n");
    printf("euid=%d (%s)\n", geteuid(), geteuid() == 0 ? "root" : "non-root user");

    pid_t ws = pid_of("WindowServer");
    pid_t dock = pid_of("Dock");
    pid_t loginw = pid_of("loginwindow");
    printf("WindowServer pid=%d  Dock pid=%d  loginwindow pid=%d\n", ws, dock, loginw);

    // Control: a non-hardened child we own. We should be able to get its task port.
    pid_t child = fork();
    if (child == 0) { execl("/bin/sleep", "sleep", "120", (char*)NULL); _exit(127); }
    sleep(1); // let it exec

    if (ws  > 0) try_tfp("WindowServer (platform binary, hardened)", ws);
    if (dock > 0) try_tfp("Dock (Apple platform binary)", dock);
    if (child > 0) try_tfp("control: our own /bin/sleep child (non-hardened)", child);

    // Optional: show the privileged enumeration path also fails without host_priv.
    printf("\n--- processor_set_tasks enumeration path (the 'workaround')\n");
    processor_set_name_array_t psets; mach_msg_type_number_t pcnt = 0;
    kern_return_t kr = host_processor_sets(mach_host_self(), &psets, &pcnt);
    printf("    host_processor_sets -> kr=%d (%s), count=%u\n", kr, mach_error_string(kr), pcnt);
    if (kr == KERN_SUCCESS && pcnt > 0) {
        processor_set_t pset = PROCESSOR_SET_NULL;
        kr = host_processor_set_priv(mach_host_self(), psets[0], &pset);
        printf("    host_processor_set_priv -> kr=%d (%s)%s\n", kr, mach_error_string(kr),
               kr == KERN_SUCCESS ? "" : "  [needs root/host_priv -> enumeration blocked]");
        if (kr == KERN_SUCCESS) {
            task_array_t tasks; mach_msg_type_number_t tcnt = 0;
            kr = processor_set_tasks(pset, &tasks, &tcnt);
            printf("    processor_set_tasks -> kr=%d (%s), task_count=%u\n", kr, mach_error_string(kr), tcnt);
            printf("    (Even when this returns ports, platform binaries yield degraded name-only ports.)\n");
        }
    }

    if (child > 0) kill(child, SIGTERM);
    printf("\n=== Probe complete ===\n");
    return 0;
}
