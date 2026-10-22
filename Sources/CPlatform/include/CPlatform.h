#ifndef CELL_PLATFORM_H
#define CELL_PLATFORM_H
#include <stdint.h>
#include <stddef.h>
typedef struct {
    int32_t pid;
    int32_t parent_pid;
    uint64_t started;
    uint64_t cpu_ns;
    uint64_t energy_nj;
    uint64_t wakeups;
    uint64_t memory_bytes;
    int has_energy;
    char name[256];
} CellProcess;
// Returns the number written, or -1 on enumeration failure. Same-user processes only.
int cell_read_processes(CellProcess *output, int capacity);
#endif
