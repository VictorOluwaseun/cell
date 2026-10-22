#include "CPlatform.h"
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

int cell_read_processes(CellProcess *output, int capacity) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return -1;
    int slots = count + 256;
    pid_t *pids = calloc((size_t)slots, sizeof(pid_t));
    if (!pids) return -1;
    count = proc_listallpids(pids, slots * (int)sizeof(pid_t));
    if (count < 0) { free(pids); return -1; }
    if (count > slots) count = slots;
    int written = 0;
    for (int i = 0; i < count && written < capacity; i++) {
        struct proc_bsdinfo bsd = {0};
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)
            || bsd.pbi_uid != getuid()) continue;
        CellProcess row = {0};
        struct rusage_info_v6 usage = {0};
        int ok = proc_pid_rusage(pids[i], RUSAGE_INFO_V6, (rusage_info_t *)&usage);
        if (ok == 0) {
            row.energy_nj = usage.ri_energy_nj;
            row.has_energy = usage.ri_energy_nj > 0;
        } else {
            struct rusage_info_v2 fallback = {0};
            if (proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&fallback) != 0) continue;
            // v2 is a common prefix of v6.
            memcpy(&usage, &fallback, sizeof(fallback));
        }
        row.pid = pids[i];
        row.parent_pid = (int32_t)bsd.pbi_ppid;
        row.started = usage.ri_proc_start_abstime;
        row.cpu_ns = usage.ri_user_time + usage.ri_system_time;
        row.wakeups = usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups;
        row.memory_bytes = usage.ri_phys_footprint;
        proc_name(pids[i], row.name, sizeof(row.name));
        output[written++] = row;
    }
    free(pids);
    return written;
}
